#!/bin/bash
set -e

PLATFORM=$1

if [ -z "$PLATFORM" ]; then
  echo "Usage: ./deploy.sh [ios|android|both]"
  exit 1
fi

echo "📦 Bumping build number in pubspec.yaml..."
# ใช้ perl เพื่อค้นหาบรรทัด version: x.y.z+123 และบวกเลขตัวหลังขึ้น 1 อัตโนมัติ
perl -i -pe 's/^(version:\s+\d+\.\d+\.\d+\+)(\d+)$/$1 . ($2 + 1)/e' pubspec.yaml

VERSION=$(grep '^version:' pubspec.yaml | awk '{print $2}')
echo "✅ New version is: $VERSION"

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

echo "🎉 All deployments complete!"
