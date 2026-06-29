#!/bin/bash
set -e

PLATFORM=$1

if [ -z "$PLATFORM" ]; then
  echo "Usage: ./deploy.sh [ios|android|both]"
  exit 1
fi

echo "📦 Bumping build number in pubspec.yaml..."
# The versionCode is baked into the binary at build time, so the bump must
# happen BEFORE building. To avoid inflating the version on a failed/aborted
# run (the old behaviour: every crash left a +1), restore the original version
# line on any error. Only a fully successful deploy keeps the bump.
ORIG_VERSION_LINE=$(grep '^version:' pubspec.yaml)
restore_version() {
  perl -i -pe "s/^version:.*/${ORIG_VERSION_LINE}/" pubspec.yaml
  echo "↩️  Deploy failed — reverted version to: ${ORIG_VERSION_LINE}"
}
trap restore_version ERR

# ใช้ perl เพื่อค้นหาบรรทัด version: x.y.z+123 และบวกเลขตัวหลังขึ้น 1 อัตโนมัติ
perl -i -pe 's/^(version:\s+\d+\.\d+\.\d+\+)(\d+)$/$1 . ($2 + 1)/e' pubspec.yaml

VERSION=$(grep '^version:' pubspec.yaml | awk '{print $2}')
echo "✅ New version is: $VERSION"

echo "📝 Generating release notes using LLM..."
dart run tool/generate_changelog.dart
export CHANGELOG=$(cat changelog.txt)
echo "--- Release Notes ---"
cat changelog.txt
echo "---------------------"


if [ "$PLATFORM" == "android" ] || [ "$PLATFORM" == "both" ]; then
  echo "🚀 Deploying Android..."
  cd android
  bundle exec fastlane beta
  cd ..
fi

if [ "$PLATFORM" == "ios" ] || [ "$PLATFORM" == "both" ]; then
  echo "🍏 Deploying iOS..."
  cd ios
  fastlane beta
  cd ..
fi

trap - ERR # success — keep the bump
echo "🎉 All deployments complete! Shipped $VERSION"
