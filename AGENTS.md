# Communication preference

- 默认与用户交流时，中文约 70%、英文约 30%；以简洁易懂的中文为主，自然穿插 English words and short phrases。比例是整体风格目标，不必逐句或精确计数。
- 不要逐段提供中英双语重复翻译。Keep it natural, clear, and concise.
- 代码、命令、路径、标识符，以及用户指定语言的产品文案，保持其原本或指定的语言，不强行混写；用户明确要求其他语言或格式时，遵从当前要求。

# Local macOS builds and installation

- Installed builds must keep Bundle ID `OAKunO.DynamicIsland` and use the
  `DynamicIsland Local Development` code-signing identity in the login keychain.
- Build with `zsh scripts/build-and-install.sh`. To install, quit the running app
  normally, then run `zsh scripts/build-and-install.sh --install`. Reopen it only
  after installation and signature verification succeed.
- Never install an ad-hoc (`codesign --sign -`) or unsigned build. Do not work
  around a missing identity by disabling code signing for an installed build.
- `zsh scripts/setup-local-signing.sh` creates the local identity once; subsequent
  runs reuse it. Do not delete or regenerate that identity to fix a build error.
  Private keys stay in Keychain and must not be committed or printed.
- Verify an installed bundle with
  `zsh scripts/verify-app-signature.sh /Applications/DynamicIsland.app`.
- Real screen recording still requires the user's explicit authorization;
  signature verification does not constitute consent to capture the screen.
