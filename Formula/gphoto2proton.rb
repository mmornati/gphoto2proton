class Gphoto2proton < Formula
  desc "Migrate Google Photos Takeout archives to Proton Drive"
  homepage "https://github.com/mmornati/gphoto2proton"
  license "MIT"

  version "0.2.0"

  on_macos do
    on_arm do
      url "https://github.com/mmornati/gphoto2proton/releases/download/v0.2.0/gphoto2proton_0.2.0_darwin_arm64.tar.gz"
      sha256 "0019dfc4b32d63c1392aa264aed2253c1e0c2fb09216f8e2cc269bbfb8bb49b5"
    end
    on_intel do
      url "https://github.com/mmornati/gphoto2proton/releases/download/v0.2.0/gphoto2proton_0.2.0_darwin_amd64.tar.gz"
      sha256 "0019dfc4b32d63c1392aa264aed2253c1e0c2fb09216f8e2cc269bbfb8bb49b5"
    end
  end

  on_linux do
    on_arm do
      url "https://github.com/mmornati/gphoto2proton/releases/download/v0.2.0/gphoto2proton_0.2.0_linux_arm64.tar.gz"
      sha256 "0019dfc4b32d63c1392aa264aed2253c1e0c2fb09216f8e2cc269bbfb8bb49b5"
    end
    on_intel do
      url "https://github.com/mmornati/gphoto2proton/releases/download/v0.2.0/gphoto2proton_0.2.0_linux_amd64.tar.gz"
      sha256 "0019dfc4b32d63c1392aa264aed2253c1e0c2fb09216f8e2cc269bbfb8bb49b5"
    end
  end

  def install
    bin.install "gphoto2proton"
  end

  test do
    system "#{bin}/gphoto2proton", "version"
  end
end
