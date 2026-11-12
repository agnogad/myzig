# Packaging

`myzig package` turns a built application into something a user can install.
It is deliberately small: it stages a directory and writes the one file every
Linux desktop needs. Formats that need more machinery are listed at the end
with what is still missing.

## What it produces

```sh
zig build install          # build the program first
myzig package              # stage it
```

```text
dist/
  notes-0.1.0/
    notes                  the executable, mode 0755
    notes.desktop          a freedesktop entry that points at it
```

Options:

| Option | Default | Meaning |
| --- | --- | --- |
| `--name NAME` | the project's `build.zig.zon` name | program and directory name |
| `--version VERSION` | `0.1.0` | written into the desktop entry's `Comment` |
| `--out DIR` | `dist` | where the staged directory goes |

The command refuses to run when `zig-out/bin/NAME` does not exist, rather than
writing a bundle with a missing program in it.

## The desktop entry

```ini
[Desktop Entry]
Type=Application
Name=notes
Exec=notes
Comment=notes 0.1.0
Terminal=false
Categories=Utility;
```

`Version` is **not** the application's version. In the freedesktop
specification that key is the version of the entry format itself, and putting
an application version there makes `desktop-file-validate` reject the file. The
application version goes in `Comment`, or in a field you add yourself, such as
`X-AppVersion`.

An entry is only valid if every key it sets is a known one, so a packaging step
that passes `desktop-file-validate` cleanly is worth running:

```sh
desktop-file-validate dist/notes-0.1.0/notes.desktop
```

## Installing by hand

```sh
install -Dm755 dist/notes-0.1.0/notes ~/.local/bin/notes
install -Dm644 dist/notes-0.1.0/notes.desktop \
    ~/.local/share/applications/notes.desktop
```

Installing the desktop entry is what makes the program appear in the
application menu; the `.desktop` file's `Exec` is looked up on `PATH`, so the
program must be somewhere the session searches.

## Shipping the libraries

MyZig loads GTK, WebKitGTK, cairo and X11 at runtime rather than linking them,
so the binary itself is small and starts on a machine that lacks them — it
reports a named error instead of failing in the loader before `main`. What that
does *not* do is make the libraries unnecessary: a bundle for another machine
still needs them, or needs the application to avoid the feature that maps them.

A native-only application needs GTK 3 for its window and nothing else. A
page-only application needs GTK 3 and WebKitGTK 4.1. An application that binds
global shortcuts needs X11 and will report `NotSupported` on a Wayland-only
session, because Wayland has no equivalent grab.

## Not built yet

These are honest gaps, not oversights:

* **AppImage.** An AppImage is a squashfs image with a runtime prepended. The
  runtime is a binary that has to be shipped, and `appimagetool` is not present
  here, so the format is not produced. `mksquashfs` plus a checked-in runtime
  would be enough to add it.
* **`.deb`.** A Debian package is an `ar` archive of `debian-binary`,
  `control.tar.gz` and `data.tar.gz`. Nothing about it is hard, but it needs a
  control-file generator (maintainer, dependencies, section) that the project
  does not have yet.
* **`.app` bundle and code signing.** macOS only, and the macOS backend is not
  written.
* **Auto-update.** Needs a feed format, a signature key and a download path.
  Not started, and not promised in the public API.

Until then, the staged directory plus a tarball of it is what `myzig package`
gives you, and it is enough to hand a working program to someone else.
