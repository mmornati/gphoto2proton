class Gphoto2proton < Formula
  desc "Migrate Google Photos Takeout archives to Proton Drive"
  homepage "https://github.com/mmornati/gphoto2proton"
  license "MIT"

  version "0.1.0"

  on_macos do
    on_arm do
      url "https://github.com/mmornati/gphoto2proton/releases/download/v0.1.0/gphoto2proton_0.1.0_darwin_arm64.tar.gz"
      sha256 "0000000000000000000000000000000000000000000000000000000000000000"
    end
    on_intel do
      url "https://github.com/mmornati/gphoto2proton/releases/download/v0.1.0/gphoto2proton_0.1.0_darwin_amd64.tar.gz"
      sha256 "0000000000000000000000000000000000000000000000000000000000000000"
    end
  end

  on_linux do
    on_arm do
      url "https://github.com/mmornati/gphoto2proton/releases/download/v0.1.0/gphoto2proton_0.1.0_linux_arm64.tar.gz"
      sha256 "0000000000000000000000000000000000000000000000000000000000000000"
    end
    on_intel do
      url "https://github.com/mmornati/gphoto2proton/releases/download/v0.1.0/gphoto2proton_0.1.0_linux_amd64.tar.gz"
      sha256 "0000000000000000000000000000000000000000000000000000000000000000"
    end
  end

  def install
    bin.install "gphoto2proton"
  end

  test do
    system "#{bin}/gphoto2proton", "version"
  end
end
