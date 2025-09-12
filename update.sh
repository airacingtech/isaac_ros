#!/usr/bin/env bash
set -euo pipefail

# Change this to your GPG key ID
KEYID="EAF9167959BFE60C"

# Repo location (adjust if needed)
REPO_DIR="$(dirname "$0")/docs"
cd "$REPO_DIR"

echo "[*] Cleaning old metadata..."
rm -f Packages.gz Release Release.gpg isaac_ros.gpg

echo "[*] Generating Packages.gz..."
dpkg-scanpackages . /dev/null | gzip -9c > Packages.gz

echo "[*] Generating Release file..."
{
  echo "Origin: isaac_ros"
  echo "Label: isaac_ros"
  echo "Suite: stable"
  echo "Codename: jammy"
  echo "Architectures: amd64"
  echo "Components: main"
  echo "Description: Isaac ROS APT repo"
  echo "Date: $(date -Ru)"
  echo "MD5Sum:"
  md5sum Packages.gz | awk '{print " " $1 " " length($2) " Packages.gz"}'
  echo "SHA256:"
  sha256sum Packages.gz | awk '{print " " $1 " " length($2) " Packages.gz"}'
} > Release

echo "[*] Signing Release..."
gpg -u "$KEYID" -abs -o Release.gpg Release

echo "[*] Exporting public key..."
gpg --armor --export "$KEYID" > isaac_ros.gpg

echo "[*] Repo metadata updated."
echo "Now run:"
echo "  git add Packages.gz Release Release.gpg isaac_ros.gpg"
echo "  git commit -m 'Update repo metadata'"
echo "  git push origin gh-pages"

