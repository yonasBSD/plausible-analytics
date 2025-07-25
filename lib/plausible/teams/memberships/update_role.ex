defmodule Plausible.Teams.Memberships.UpdateRole do
  @moduledoc """
  Service for updating role of a team member.
  """

  use Plausible

  alias Plausible.Repo
  alias Plausible.Teams
  alias Plausible.Teams.Memberships

  def update(nil, _, _, _), do: {:error, :permission_denied}

  def update(team, user_id, new_role_str, current_user) do
    new_role = String.to_existing_atom(new_role_str)

    with :ok <- check_valid_role(new_role),
         {:ok, team_membership} <- Memberships.get_team_membership(team, user_id),
         {:ok, current_user_role} <- Memberships.team_role(team, current_user),
         granting_to_self? = team_membership.user_id == current_user.id,
         :ok <-
           check_can_grant_role(
             current_user_role,
             team_membership.role,
             new_role,
             granting_to_self?
           ),
         :ok <- check_owner_can_get_demoted(team, team_membership.role, new_role),
         team_membership = Repo.preload(team_membership, :user),
         :ok <- check_can_promote_to_owner(team, team_membership.user, new_role) do
      if team_membership.role == :guest and new_role != :guest do
        team_membership.user.email
        |> PlausibleWeb.Email.guest_to_team_member_promotion(
          team,
          current_user
        )
        |> Plausible.Mailer.send()
      end

      team_membership =
        team_membership
        |> Ecto.Changeset.change(role: new_role)
        |> Repo.update!()

      :ok = maybe_prune_guest_memberships(team_membership)

      {:ok, team_membership}
    end
  end

  on_ee do
    defp check_can_promote_to_owner(team, user, :owner) do
      if team.policy.force_sso == :all_but_owners and not Plausible.Auth.TOTP.enabled?(user) do
        {:error, :disabled_2fa}
      else
        :ok
      end
    end

    defp check_can_promote_to_owner(_team, _user, _new_role), do: :ok
  else
    defp check_can_promote_to_owner(_team, _user, _new_role) do
      # The `else` branch is not reachable.
      # This a workaround for Elixir 1.18+ compiler
      # being too smart.
      if :erlang.phash2(1, 1) == 0 do
        :ok
      else
        {:error, :disabled_2fa}
      end
    end
  end

  defp check_valid_role(role) do
    if role in (Teams.Membership.roles() -- [:guest]) do
      :ok
    else
      {:error, :invalid_role}
    end
  end

  defp check_owner_can_get_demoted(team, :owner, new_role) when new_role != :owner do
    if Memberships.owners_count(team) > 1 do
      :ok
    else
      {:error, :only_one_owner}
    end
  end

  defp check_owner_can_get_demoted(_team, _current_role, _new_role), do: :ok

  defp check_can_grant_role(user_role, _from_role, to_role, true) do
    if can_grant_role_to_self?(user_role, to_role) do
      :ok
    else
      {:error, :permission_denied}
    end
  end

  defp check_can_grant_role(user_role, from_role, to_role, false) do
    if can_grant_role_to_other?(user_role, from_role, to_role) do
      :ok
    else
      {:error, :permission_denied}
    end
  end

  defp can_grant_role_to_self?(:owner, :admin), do: true
  defp can_grant_role_to_self?(:owner, :editor), do: true
  defp can_grant_role_to_self?(:owner, :viewer), do: true
  defp can_grant_role_to_self?(:owner, :billing), do: true
  defp can_grant_role_to_self?(:admin, :editor), do: true
  defp can_grant_role_to_self?(:admin, :viewer), do: true
  defp can_grant_role_to_self?(:admin, :billing), do: true
  defp can_grant_role_to_self?(_, _), do: false

  defp can_grant_role_to_other?(:owner, _, _), do: true
  defp can_grant_role_to_other?(:admin, :admin, :admin), do: true
  defp can_grant_role_to_other?(:admin, :admin, :editor), do: true
  defp can_grant_role_to_other?(:admin, :admin, :viewer), do: true
  defp can_grant_role_to_other?(:admin, :admin, :billing), do: true
  defp can_grant_role_to_other?(:admin, :editor, :admin), do: true
  defp can_grant_role_to_other?(:admin, :editor, :editor), do: true
  defp can_grant_role_to_other?(:admin, :editor, :viewer), do: true
  defp can_grant_role_to_other?(:admin, :editor, :billing), do: true
  defp can_grant_role_to_other?(:admin, :viewer, :admin), do: true
  defp can_grant_role_to_other?(:admin, :viewer, :editor), do: true
  defp can_grant_role_to_other?(:admin, :viewer, :viewer), do: true
  defp can_grant_role_to_other?(:admin, :viewer, :billing), do: true
  defp can_grant_role_to_other?(:admin, :billing, :billing), do: true
  defp can_grant_role_to_other?(_, _, _), do: false

  defp maybe_prune_guest_memberships(%Teams.Membership{role: :guest}),
    do: :ok

  defp maybe_prune_guest_memberships(%Teams.Membership{} = team_membership) do
    team_membership
    |> Ecto.assoc(:guest_memberships)
    |> Repo.delete_all()

    :ok
  end
end
