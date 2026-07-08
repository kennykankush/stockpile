cask "fleetwatch" do
  version "0.5.0"
  sha256 "e4f0a7da9a64e9aa3e298d717bad8e562dc035a38822fb9194409636695eaa70"

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
