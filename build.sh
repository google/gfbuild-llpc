#!/usr/bin/env bash

# Copyright 2019 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -x
set -e
set -u

WORK="$(pwd)"

# Old bash versions can't expand empty arrays, so we always include at least this option.
CMAKE_OPTIONS=("-DCMAKE_OSX_ARCHITECTURES=x86_64")

help | head

uname

case "$(uname)" in
"Linux")
  NINJA_OS="linux"
  BUILD_PLATFORM="Linux_x64"
  PYTHON="python3"
  sudo DEBIAN_FRONTEND=noninteractive apt-get -qy install patchelf
  df -h
  sudo swapoff -a
  sudo rm -f /swapfile
  sudo apt clean
  # shellcheck disable=SC2046
  docker rmi -f $(docker image ls -aq)
  df -h
  ;;

"Darwin")
  NINJA_OS="mac"
  BUILD_PLATFORM="Mac_x64"
  PYTHON="python3"
  brew install md5sha1sum
  ;;

"MINGW"*|"MSYS_NT"*)
  NINJA_OS="win"
  BUILD_PLATFORM="Windows_x64"
  PYTHON="python"
  CMAKE_OPTIONS+=("-DCMAKE_C_COMPILER=cl.exe" "-DCMAKE_CXX_COMPILER=cl.exe")
  choco install zip
  ;;

*)
  echo "Unknown OS"
  exit 1
  ;;
esac

###### START EDIT ######
TARGET_REPO_ORG="GPUOpen-Drivers"
TARGET_REPO_NAME="AMDVLK"
BUILD_REPO_ORG="google"
BUILD_REPO_NAME="gfbuild-llpc"
###### END EDIT ######

COMMIT_ID="$(cat "${WORK}/COMMIT_ID")"

ARTIFACT="${BUILD_REPO_NAME}"
ARTIFACT_VERSION="${COMMIT_ID}"
GROUP_DOTS="github.${BUILD_REPO_ORG}"
GROUP_SLASHES="github/${BUILD_REPO_ORG}"
TAG="${GROUP_SLASHES}/${ARTIFACT}/${ARTIFACT_VERSION}"

BUILD_REPO_SHA="${GITHUB_SHA}"
CLASSIFIER="${BUILD_PLATFORM}_${CONFIG}"
POM_FILE="${BUILD_REPO_NAME}-${ARTIFACT_VERSION}.pom"
INSTALL_DIR="${ARTIFACT}-${ARTIFACT_VERSION}-${CLASSIFIER}"

export PATH="${HOME}/bin:$PATH"

mkdir -p "${HOME}/bin"

pushd "${HOME}/bin"

# Install github-release-retry.
"${PYTHON}" -m pip install --user 'github-release-retry==1.*'

# Install ninja.
curl -fsSL -o ninja-build.zip "https://github.com/ninja-build/ninja/releases/download/v1.9.0/ninja-${NINJA_OS}.zip"
unzip ninja-build.zip

ls

popd

###### START EDIT ######
CMAKE_GENERATOR="Ninja"
CMAKE_BUILD_TYPE="${CONFIG}"
CMAKE_OPTIONS+=("-DBUILD_WAYLAND_SUPPORT=0")

curl -fsSL -o repo https://storage.googleapis.com/git-repo-downloads/repo
chmod a+x repo
mkdir vulkandriver
cd vulkandriver
../repo init -u "https://github.com/${TARGET_REPO_ORG}/${TARGET_REPO_NAME}.git" -b "${COMMIT_ID}"
../repo sync
cd drivers

pushd spvgen/external
/usr/bin/python fetch_external_sources.py
popd

cd xgl

# Get the release description using git now because we will delete the git repos to conserve space.
DESCRIPTION="$(echo -e "Automated build for ${TARGET_REPO_NAME} version ${COMMIT_ID}.\n$(git log --graph -n 3 --abbrev-commit --pretty='format:%h - %s <%an>')")"
# Delete git data to conserve space.
rm -rf ../../.repo

###### END EDIT ######

###### BEGIN BUILD ######

###### END BUILD ######

###### START EDIT ######

cmake -G "${CMAKE_GENERATOR}" -H. -Bbuilds/Release64 "-DCMAKE_BUILD_TYPE=${CMAKE_BUILD_TYPE}" "${CMAKE_OPTIONS[@]}"
cd builds/Release64

cmake --build . --config "${CMAKE_BUILD_TYPE}" --target spvgen
mkdir -p "${INSTALL_DIR}/lib"
cp spvgen/spvgen.* "${INSTALL_DIR}/lib/"

# Add .pdb files on Windows.
case "$(uname)" in
"Linux")
  ;;

"Darwin")
  ;;

"MINGW"*|"MSYS_NT"*)
  "${PYTHON}" "${WORK}/add_pdbs.py" . "${INSTALL_DIR}/lib"
  ;;

*)
  echo "Unknown OS"
  exit 1
  ;;
esac

# Conserve space and now build amdllpc.
rm -rf spvgen/

cmake --build . --config "${CMAKE_BUILD_TYPE}" --target amdllpc

mkdir -p "${INSTALL_DIR}/bin"

cp compiler/llpc/amdllpc* "${INSTALL_DIR}/bin/"

# Add .pdb files on Windows.
case "$(uname)" in
"Linux")
  ;;

"Darwin")
  ;;

"MINGW"*|"MSYS_NT"*)
  "${PYTHON}" "${WORK}/add_pdbs.py" . "${INSTALL_DIR}/bin"
  ;;

*)
  echo "Unknown OS"
  exit 1
  ;;
esac

# Conserve space.
rm -rf llvm/

# Set the rpath of amdllpc so spvgen.so will always be found.
# shellcheck disable=SC2016
patchelf --set-rpath '$ORIGIN/../lib' "${INSTALL_DIR}/bin/amdllpc"

for f in "${INSTALL_DIR}/bin/"* "${INSTALL_DIR}/lib/"*; do
  echo "${BUILD_REPO_SHA}">"${f}.build-version"
  cp "${WORK}/COMMIT_ID" "${f}.version"
done
###### END EDIT ######

GRAPHICSFUZZ_COMMIT_SHA="b82cf495af1dea454218a332b88d2d309657594d"
OPEN_SOURCE_LICENSES_URL="https://github.com/google/gfbuild-graphicsfuzz/releases/download/github/google/gfbuild-graphicsfuzz/${GRAPHICSFUZZ_COMMIT_SHA}/OPEN_SOURCE_LICENSES.TXT"

# Add licenses file.
curl -fsSL -o OPEN_SOURCE_LICENSES.TXT "${OPEN_SOURCE_LICENSES_URL}"
cp OPEN_SOURCE_LICENSES.TXT "${INSTALL_DIR}/"

# zip file.
pushd "${INSTALL_DIR}"
zip -r "../${INSTALL_DIR}.zip" ./*
popd

sha1sum "${INSTALL_DIR}.zip" >"${INSTALL_DIR}.zip.sha1"

# POM file.
sed -e "s/@GROUP@/${GROUP_DOTS}/g" -e "s/@ARTIFACT@/${ARTIFACT}/g" -e "s/@VERSION@/${ARTIFACT_VERSION}/g" "${WORK}/fake_pom.xml" >"${POM_FILE}"

sha1sum "${POM_FILE}" >"${POM_FILE}.sha1"

# Only release from master branch commits.
# shellcheck disable=SC2153
if test "${GITHUB_REF}" != "refs/heads/master"; then
  exit 0
fi

# We do not use the GITHUB_TOKEN provided by GitHub Actions.
# We cannot set enviroment variables or secrets that start with GITHUB_ in .yml files,
# but the github-release-retry tool requires GITHUB_TOKEN, so we set it here.
export GITHUB_TOKEN="${GH_TOKEN}"

"${PYTHON}" -m github_release_retry.github_release_retry \
  --user "${BUILD_REPO_ORG}" \
  --repo "${BUILD_REPO_NAME}" \
  --tag_name "${TAG}" \
  --target_commitish "${BUILD_REPO_SHA}" \
  --body_string "${DESCRIPTION}" \
  "${INSTALL_DIR}.zip"

"${PYTHON}" -m github_release_retry.github_release_retry \
  --user "${BUILD_REPO_ORG}" \
  --repo "${BUILD_REPO_NAME}" \
  --tag_name "${TAG}" \
  --target_commitish "${BUILD_REPO_SHA}" \
  --body_string "${DESCRIPTION}" \
  "${INSTALL_DIR}.zip.sha1"

# Don't fail if pom cannot be uploaded, as it might already be there.

"${PYTHON}" -m github_release_retry.github_release_retry \
  --user "${BUILD_REPO_ORG}" \
  --repo "${BUILD_REPO_NAME}" \
  --tag_name "${TAG}" \
  --target_commitish "${BUILD_REPO_SHA}" \
  --body_string "${DESCRIPTION}" \
  "${POM_FILE}" || true

"${PYTHON}" -m github_release_retry.github_release_retry \
  --user "${BUILD_REPO_ORG}" \
  --repo "${BUILD_REPO_NAME}" \
  --tag_name "${TAG}" \
  --target_commitish "${BUILD_REPO_SHA}" \
  --body_string "${DESCRIPTION}" \
  "${POM_FILE}.sha1" || true

# Don't fail if OPEN_SOURCE_LICENSES.TXT cannot be uploaded, as it might already be there.

"${PYTHON}" -m github_release_retry.github_release_retry \
  --user "${BUILD_REPO_ORG}" \
  --repo "${BUILD_REPO_NAME}" \
  --tag_name "${TAG}" \
  --target_commitish "${BUILD_REPO_SHA}" \
  --body_string "${DESCRIPTION}" \
  "OPEN_SOURCE_LICENSES.TXT" || true
