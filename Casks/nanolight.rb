cask "nanolight" do
  version "0.2.13"
  sha256 "e66875202bda54782059143390b4eef9aa464d435276c7c362c01ae234d7d483"

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
