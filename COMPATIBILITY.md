# Pane 0.2 compatibility and release validation

This is the repeatable developer-preview matrix. Record the Pane build, macOS version, Mac model, shell, and date for every manual run. A pass requires the expected presentation, correct input and focus, correct PTY resize, one block and one output stream, honest completion state, and no secure-input persistence after relaunch.

| Program or behavior | Expected presentation | Automated coverage | Manual result |
| --- | --- | --- | --- |
| Basic zsh commands | Blocks | Persistent PTY and block lifecycle integration tests | Pending release pass |
| Multiline shell input | Blocks composer | Multiline and continuation integration tests | Pending release pass |
| `cat` with stdin | Line-oriented active block | Line-oriented input tests | Pending release pass |
| `sudo` | Secure authoritative terminal | ECHO-off and secure-input tests | Pending release pass |
| `ssh` password/session | Secure then direct/expanded terminal | ECHO/direct routing tests | Pending release pass |
| `vim`, `nano`, `less`, `top` | Expanded authoritative terminal | Alternate-screen protocol tests | Pending release pass |
| `fzf` | Direct or expanded terminal | Raw-termios routing tests | Pending release pass |
| `tmux` | Full authoritative terminal | PTY and alternate-screen primitives | Pending release pass |
| OpenCode | Expanded/direct authoritative terminal | Known-process routing tests | Pending release pass |
| Python and Node REPLs | Direct or line-oriented by termios | Raw/canonical routing tests | Pending release pass |
| Git interactive rebase | Expanded authoritative terminal | Alternate-screen primitives | Pending release pass |
| Long build output | Active block | Bounded capture and live mirror tests | Pending release pass |
| Unicode and emoji | Correct SwiftTerm/block rendering | Parser UTF-8 coverage | Pending release pass |
| Resize during TUI | Correct `TIOCSWINSZ` propagation | Resize integration coverage | Pending release pass |
| Control-C and Control-D | Correct ETX/EOT behavior | Integration tests | Pending release pass |

## Per-program procedure

1. Start the program from Blocks and verify the destination indicator and expected presentation.
2. Type into the authoritative terminal; resize the window and verify the TUI redraws once.
3. Click another Pane control, trigger continuing output, and verify focus is not stolen unexpectedly.
4. Focus the terminal manually, exit normally, and verify return to Blocks, one completed block, correct status, and no duplicate or lost output.
5. Where relevant, repeat with Control-C, Direct Input, Full Terminal, Restart Shell, and force quit/relaunch.
6. For password or secure-input cases, inspect restored history and local diagnostics and confirm that content and inferred length are absent.

## Clean-install checklist

Run on a supported Mac that has not built Pane and has no Pane support directory. Copy the built `Pane.app` without Xcode, then verify Finder launch, bundled SwiftTerm resources, zsh startup/integration, local directory permissions, icon/metadata, onboarding, offline core use, relaunch restoration, directory fallback, every local-data clearing action, and recovery-file actions after a corrupted-database simulation.

Developer-preview signing may be local or ad hoc. Developer ID signing, hardened runtime, notarization, and an update channel remain separate public-alpha release work.
