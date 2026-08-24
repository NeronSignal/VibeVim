# Contributing

Thanks for helping improve Neovim Codex Workbench.

## Before opening a pull request

1. Create a focused branch from main.
2. Reproduce the change with a clean Neovim test profile when possible.
3. Run a headless startup check:

~~~bash
nvim --headless -u ./init.lua -c 'lua print(vim.g.colors_name)' -c 'qa!'
~~~

4. Describe the operating system, terminal emulator, Neovim version, and the relevant :messages output.
5. Check that no API keys, tokens, private endpoints, machine-local paths, or project logs are included.

## Pull requests

Keep each pull request small enough to review. Explain the user-visible effect, compatibility considerations, and how you tested it. UI changes should include a screenshot or a short reproduction when that makes the behavior clearer.

## Issues

Use the issue templates for reproducible bugs and feature ideas. For Codex or provider problems, redact credentials and include only the command/configuration shape needed to reproduce the issue.
