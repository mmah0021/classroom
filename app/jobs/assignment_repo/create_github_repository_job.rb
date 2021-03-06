# frozen_string_literal: true

class AssignmentRepo
  class CreateGitHubRepositoryJob < ApplicationJob
    CREATE_REPO         = "Creating repository"
    ADDING_COLLABORATOR = "Adding collaborator"
    IMPORT_STARTER_CODE = "Importing starter code"

    queue_as :create_repository

    # Create an AssignmentRepo
    #
    # assignment - The Assignment that will own the AssignmentRepo
    # user       - The User that the AssignmentRepo will belong to
    # retries    - The number of times the job will automatically retry
    #
    # rubocop:disable MethodLength
    # rubocop:disable AbcSize
    # rubocop:disable CyclomaticComplexity
    # rubocop:disable PerceivedComplexity
    def perform(assignment, user, retries: 0)
      start = Time.zone.now

      invite_status = assignment.invitation.status(user)

      return unless invite_status.waiting? || invite_status.errored_creating_repo?
      invite_status.creating_repo!

      ActionCable.server.broadcast(
        RepositoryCreationStatusChannel.channel(user_id: user.id),
        text: CREATE_REPO,
        status: invite_status.status
      )

      creator = Creator.new(assignment: assignment, user: user)
      creator.verify_organization_has_private_repos_available!
      assignment_repo = assignment.assignment_repos.build(
        github_repo_id: creator.create_github_repository!,
        user: user
      )
      creator.add_user_to_repository!(assignment_repo.github_repo_id)
      creator.push_starter_code!(assignment_repo.github_repo_id) if assignment.starter_code?

      begin
        assignment_repo.save!
      rescue ActiveRecord::RecordInvalid => err
        logger.warn(err.message)
        raise Creator::Result::Error, Creator::DEFAULT_ERROR_MESSAGE
      end

      duration_in_millseconds = (Time.zone.now - start) * 1_000
      GitHubClassroom.statsd.timing("v2_exercise_repo.create.time", duration_in_millseconds)
      GitHubClassroom.statsd.increment("v2_exercise_repo.create.success")

      if assignment.starter_code?
        invite_status.importing_starter_code!
        ActionCable.server.broadcast(
          RepositoryCreationStatusChannel.channel(user_id: user.id),
          text: IMPORT_STARTER_CODE,
          status: invite_status.status
        )
        PorterStatusJob.perform_later(assignment_repo, user)
      else
        invite_status.completed!
        ActionCable.server.broadcast(
          RepositoryCreationStatusChannel.channel(user_id: user.id),
          text: Creator::REPOSITORY_CREATION_COMPLETE,
          status: invite_status.status
        )
      end
    rescue Creator::Result::Error => err
      creator.delete_github_repository(assignment_repo.try(:github_repo_id))
      logger.warn(err.message)
      if retries.positive?
        invite_status.waiting!
        CreateGitHubRepositoryJob.perform_later(assignment, user, retries: retries - 1)
      else
        invite_status.errored_creating_repo!
        ActionCable.server.broadcast(
          RepositoryCreationStatusChannel.channel(user_id: user.id),
          error: err,
          status: invite_status.status
        )
        case err.message
        when Creator::REPOSITORY_CREATION_FAILED
          GitHubClassroom.statsd.increment("v2_exercise_repo.create.repo.fail")
        when Creator::REPOSITORY_COLLABORATOR_ADDITION_FAILED
          GitHubClassroom.statsd.increment("v2_exercise_repo.create.adding_collaborator.fail")
        when Creator::REPOSITORY_STARTER_CODE_IMPORT_FAILED
          GitHubClassroom.statsd.increment("v2_exercise_repo.create.importing_starter_code.fail")
        else
          GitHubClassroom.statsd.increment("v2_exercise_repo.create.fail")
        end
      end
    end
    # rubocop:enable MethodLength
    # rubocop:enable AbcSize
    # rubocop:enable CyclomaticComplexity
    # rubocop:enable PerceivedComplexity
  end
end
