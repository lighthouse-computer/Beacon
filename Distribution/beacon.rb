# SEED COPY — do not rely on this file for installs.
#
# The LIVE cask lives in the Homebrew tap repo at `Casks/beacon.rb` and is kept
# current AUTOMATICALLY by `tap-autobump.yml` (which direct-commits the latest
# release's version + verified sha256 on every release). Do NOT hand-edit the
# tap copy — the bot owns it.
#
# This seed exists only to bootstrap a brand-new tap. On the first real release,
# the autobump workflow replaces the version + sha256 below with verified
# values; until then the sha256 here is a placeholder.
cask "beacon" do
  version "1.0.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/lighthouse-computer/beacon/releases/download/v#{version}/Beacon.app.zip",
      verified: "github.com/lighthouse-computer/beacon/"
  name "Beacon"
  desc "Menu-bar utility for live per-app network monitoring"
  homepage "https://github.com/lighthouse-computer/beacon"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: ">= :ventura"

  app "Beacon.app"

  # The app is signed ad-hoc, not notarized by Apple (notarization needs a paid
  # Developer ID). Without this, Gatekeeper shows "Apple could not verify…" and
  # blocks launch. Stripping the quarantine xattr that the download path set lets
  # it open normally. Safe: the bytes came from our own GitHub release, and the
  # sha256 above already pins them.
  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-d", "-r", "com.apple.quarantine", "#{appdir}/Beacon.app"],
                   sudo: false
    # Launch right after install.
    system_command "/usr/bin/open",
                   args: ["-a", "#{appdir}/Beacon.app"],
                   sudo: false
  end

  zap trash: [
    "~/Library/Application Support/Beacon",
    "~/Library/Preferences/computer.lighthouse.beacon.plist",
    "~/Library/LaunchAgents/computer.lighthouse.beacon.plist",
  ]
end
