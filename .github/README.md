# Design (pure) — a Zeron plugin

Design screens with your agents on a Canvas beside the chat. Pure Luau, no
companion program: agents use `design_execute`, `design_state` and
`design_guide`; you edit on the Canvas in a Design tab.

## Needs

A nightly Zeron from [`hoangvu12/zeron-nightly`](https://github.com/hoangvu12/zeron-nightly).
Release Zeron builds don't have the APIs this plugin uses yet.

## Install

In Zeron's **Settings → Plugins**, install from a link and paste either one:

- `https://github.com/hoangvu12/zeron-design`: installs from this repo's
  `main` branch and updates whenever a new version is pushed.
- `https://github.com/hoangvu12/zeron-design/releases/latest`: installs the
  `.zeron-plugin` attached to the latest release.

Both are signed. Zeron checks every file against the signature, and an update
must come from the same author with a higher version. Updates show up in
**Settings → Plugins**.

## Layout

The repository's top level is the plugin folder itself (`zeron-plugin.json`,
`init.luau`, `service.luau`, …). Keep anything else in dot folders like this
one: Zeron signs every other file.
