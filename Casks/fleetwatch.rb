cask "fleetwatch" do
  version "0.3.1"
  sha256 "62f4b952faa51ecd982471b2ac36a4a443a57e45432f5aea6e235b7d587d5e20"

  url "https://github.com/kennykankush/fleetwatch/releases/download/v#{version}/Fleetwatch-#{version}.zip"
  name "Fleetwatch"
  desc "Health & hardware monitor for your fleet of machines"
  homepage "https://github.com/kennykankush/fleetwatch"

  depends_on macos: ">= :tahoe"

  app "Fleetwatch.app"

  zap trash: [
    "~/Library/Application Support/Fleetwatch",
  ]
end
