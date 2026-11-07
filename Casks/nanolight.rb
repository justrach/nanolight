cask "nanolight" do
  version "0.2.12"
  sha256 "0bf170907358b6826c4bd0127ed4297e5005303291dd9ecedf5e2dda768d5f24"

  url "https://github.com/justrach/nanolight/releases/download/v#{version}/nanolight-macos-arm64.dmg"
  name "Nanolight"
  desc "Keyboard launcher for apps, math, search and Raycast extensions"
  homepage "https://github.com/justrach/nanolight"

  livecheck do
    url :url
    strategy :github_latest
  end

  # The app updates itself; brew only installs it the first time.
  auto_updates true
  depends_on arch: :arm64
  depends_on macos: :sonoma

  app "Nanolight.app"
end
