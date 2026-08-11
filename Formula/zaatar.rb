# Homebrew formula for Zaatar. Head-only until a tagged release exists.
# Install:  brew install --HEAD ./Formula/zaatar.rb
# (or from a tap once published: brew install --HEAD <owner>/zaatar/zaatar)
class Zaatar < Formula
  desc "Local-first meeting recorder and transcriber for macOS"
  homepage "https://github.com/monojitbanerjee/zaatar"
  head "https://github.com/monojitbanerjee/zaatar.git", branch: "main"
  license "MIT"

  depends_on :macos
  depends_on "ffmpeg"
  depends_on "jq"
  depends_on "whisper-cpp"

  def install
    # Native apps (requires Xcode Command Line Tools for swiftc)
    system "swiftc", "-O", "native/zaatarcap/main.swift", "-o", "native/zaatarcap/zaatarcap",
           "-framework", "AVFoundation"
    system "swiftc", "-O", "native/zaatarprompt/main.swift", "-o", "native/zaatarprompt/zaatarprompt",
           "-framework", "AppKit"
    system "swiftc", "-O", "native/zaatarviewer/main.swift", "-o", "native/zaatarviewer/zaatarviewer",
           "-framework", "AppKit"
    system "swiftc", "-O", "native/zaatarbar/main.swift", "-o", "native/zaatarbar/zaatarbar",
           "-framework", "AppKit", "-framework", "AVFoundation", "-framework", "ServiceManagement"

    # Keep the repo layout intact in libexec (scripts resolve siblings
    # relatively), expose a single `zaatar` command on PATH.
    libexec.install Dir["*"]
    (bin/"zaatar").write_exec_script libexec/"bin/zaatar"
  end

  def caveats
    <<~EOS
      Zaatar needs a one-time interactive setup (LLM provider, calendar,
      whisper models, mic permissions):

        zaatar setup

      Recording works with any meeting app (Meet, Zoom, Teams, Webex) -
      audio is captured at the OS level. macOS 14.2+ required for
      system-audio capture; earlier versions fall back to mic-only.
    EOS
  end

  test do
    assert_match "Usage:", shell_output("#{bin}/zaatar help")
  end
end
