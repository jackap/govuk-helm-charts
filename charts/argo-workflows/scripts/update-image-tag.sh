#!/usr/bin/env bash
set -euo pipefail

BRANCH="update-image-tag/${REPO_NAME}/${ENVIRONMENT}/${IMAGE_TAG}"
FILE="charts/argocd-apps/image-tags/${ENVIRONMENT}/${REPO_NAME}"
LATEST_GIT_SHA=$(git ls-remote "https://github.com/alphagov/${REPO_NAME}" HEAD | cut -f 1)
CHANGED=false

change_image_tag() {
  git checkout -b "${BRANCH}"

  yq -i '.image_tag = env(IMAGE_TAG)' "${FILE}"

  git add "${FILE}"
  git commit -m "Update ${REPO_NAME} image tag to ${IMAGE_TAG} for ${ENVIRONMENT}"

  CHANGED=true
}

add_image_deployment_tag() {
  aws ecr get-login-password --region eu-west-1 | docker login --username AWS --password-stdin "$ECR_REGISTRY"
  MANIFEST=$(aws ecr batch-get-image --repository-name "${REPO_NAME}" --image-ids imageTag="${IMAGE_TAG}" --region eu-west-1 --query 'images[].imageManifest' --output json)
  # Every image that has a tag will then have 'deployed-to-${ENVIRONMENT}' tag added as well.
  aws ecr put-image --repository-name "${REPO_NAME}" --image-tag "deployed-to-${ENVIRONMENT}" --image-manifest "$MANIFEST"
}

git config --global user.email "${GIT_NAME}@digital.cabinet-office.gov.uk"
git config --global user.name "${GIT_NAME}"

gh auth setup-git
gh repo clone alphagov/govuk-helm-charts -- --depth 1 --branch main

cd "govuk-helm-charts" || exit 1

# Exit successfully if image tag already set
current_image_tag="$(yq '.image_tag' "${FILE}")"
if [[ "${current_image_tag}" = "${IMAGE_TAG}" ]]; then
  echo "Image tag already set as ${IMAGE_TAG}"

elif [[ "${MANUAL_DEPLOY}" = true ]]; then
  change_image_tag

# If automatic deploys, check automatic_deploys_enabled before proceeding.
# Relies on the assumption the IMAGE_TAG is a commit SHA
elif [[ "${LATEST_GIT_SHA}" = "${IMAGE_TAG}" ]]; then
  auto_deploys="$(yq '.automatic_deploys_enabled' "${FILE}")"
  # Auto deploys are enabled unless explicitly set to "false" (case insensitive).
  if [[ "${auto_deploys,,}" != "false" ]]; then
    change_image_tag
    add_image_deployment_tag
  else
    echo "Did not update image tag because automatic_deploys_enabled is set to false for app"
  fi

else
  echo "Image tag not updated for ${ENVIRONMENT}: image tag not the latest commit on main."
fi

if [[ "${CHANGED}" = true ]]; then
  git push -u origin "${BRANCH}"
  gh api repos/alphagov/govuk-helm-charts/merges -f head="${BRANCH}" -f base=main
  git push origin --delete "${BRANCH}"

  echo "Pushed changes to GitHub"
fi
