cask "stockpile" do
  version "0.3.0"
  sha256 "82e20729287da8d3b10ea5604b27b04c3e1b1a20c057dcdffcb5c8e3689a03fe"

  url "https://github.com/kennykankush/stockpile/releases/download/v#{version}/Stockpile-#{version}.zip"
  name "Stockpile"
  desc "Storage transparency for macOS — your disk, explained, not just displayed"
  homepage "https://github.com/kennykankush/stockpile"

  depends_on macos: ">= :tahoe"

  app "Stockpile.app"

  zap trash: [
    "~/Library/Application Support/Stockpile",
  ]
end
