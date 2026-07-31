class Gphoto2proton < Formula
  desc "Migrate Google Photos Takeout archives to Proton Drive"
  homepage "https://github.com/mmornati/gphoto2proton"
  license "MIT"

  version "0.1.0"

  on_macos do
    on_arm do
      url "https://github.com/mmornati/gphoto2proton/releases/download/v0.1.0/gphoto2proton_0.1.0_darwin_arm64.tar.gz"
      sha256 "c3fb9381935a8e3e1bb23d11a115d62626ce6d746279a6dd596396ba0ddaf7c5"
    end
    on_intel do
      url "https://github.com/mmornati/gphoto2proton/releases/download/v0.1.0/gphoto2proton_0.1.0_darwin_amd64.tar.gz"
      sha256 "ebbf112dece24d254602b0f7da4468cded885cbc8f4aff013986a0e542a39cf7"
    end
  end

  on_linux do
    on_arm do
      url "https://github.com/mmornati/gphoto2proton/releases/download/v0.1.0/gphoto2proton_0.1.0_linux_arm64.tar.gz"
      sha256 "85eea1c636b3263daa2eb117f078a1161f1d2e503442e2d24ac563226e40fe39"
    end
    on_intel do
      url "https://github.com/mmornati/gphoto2proton/releases/download/v0.1.0/gphoto2proton_0.1.0_linux_amd64.tar.gz"
      sha256 "ba724f08ff00c38a37d9dfcde8201b48aa38c82cb40591d2202bb395cbffa509"
    end
  end

  def install
    bin.install "gphoto2proton"
  end

  test do
    system "#{bin}/gphoto2proton", "version"
  end
end
