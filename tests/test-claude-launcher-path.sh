#!/usr/bin/env bash
# Exercise the real build setup with late installer PATH writes. Resolving
# the executable in fresh shells catches ordering bugs a file grep misses.
set -euo pipefail

WORKSHOP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WORKSHOP_ROOT
python3 - <<'PY'
import os
from pathlib import Path
import shutil
import stat
import subprocess
import tempfile
import unittest


class LauncherPathTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix="claude-startup-test-")
        self.addCleanup(self.scratch.cleanup)
        root = Path(self.scratch.name)
        self.home = root / "home"
        self.home.mkdir()
        source = Path(os.environ["WORKSHOP_ROOT"]) / "Tools/devcontainer/build"
        self.kit = root / "build"
        shutil.copytree(source, self.kit, symlinks=True)
        self.native = self.home / ".local/bin"
        self.native.mkdir(parents=True)
        for name in ("claude", "codex", "omp"):
            binary = self.native / name
            binary.write_text("#!/bin/sh\nprintf 'native fixture version\\n'\n")
            binary.chmod(0o755)
        # An unexpected installer must fail locally instead of using the network.
        (self.native / "curl").write_text("#!/bin/sh\nexit 97\n")
        (self.native / "curl").chmod(0o755)
        self.launcher = self.home / ".local/share/workshop/bin/claude"
        self.env = {
            "HOME": str(self.home),
            "PATH": os.pathsep.join((str(self.launcher.parent), str(self.native),
                                     "/usr/bin", "/bin")),
            "HARNESS_MANIFEST": str(self.home / ".devcontainer-harnesses"),
            "DEVCONTAINER_OVERLAY_DIR": str(root / "absent-overlay"),
            "SHELL": "/bin/bash",
        }
        self.seed = {}
        self.links = {}
        self.modes = {}
        self.startup(".bashrc", "BASH_USER_VALUE", 0o640, symlink=True)
        self.startup(".zshrc", "ZSH_USER_VALUE", 0o600, symlink=True)
        self.startup(".profile", "PROFILE_USER_VALUE", 0o644)
        for name in ("codex", "omp"):
            # These run after the real Claude installer, reproducing an installer
            # that steals PATH precedence after the shim was installed.
            (self.kit / ("harness-" + name + ".sh")).write_text(
                "#!/usr/bin/env bash\nset -euo pipefail\n"
                'test -x "$HOME/.local/share/workshop/bin/claude"\n'
                'source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"\n'
                'for rc in .bashrc .zshrc .profile .bash_profile .bash_login .zprofile .zlogin; do\n'
                '  [ -f "$HOME/$rc" ] || continue\n'
                "  printf '%s\\n' 'export PATH=\"$HOME/.local/bin:$PATH\"' >> \"$HOME/$rc\"\n"
                "done\n"
                "printf '%s\\n' 'late " + name + " installer completed'\n"
                "harness_record " + name + "\n"
            )

    def startup(self, name, marker, mode, symlink=False):
        path = self.home / name
        content = "# user " + name + "\nexport " + marker + "=preserved\n"
        target = path
        if symlink:
            target = self.home / ("user-" + name.lstrip("."))
            path.symlink_to(target.name)
            self.links[name] = target.name
        target.write_text(content)
        target.chmod(mode)
        self.seed[name] = content
        self.modes[name] = mode

    def setup(self):
        result = subprocess.run(["bash", str(self.kit / "setup.sh")],
                                env=self.env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result.stdout

    def assert_shell_selects_launcher(self, *options):
        result = subprocess.run(
            ["bash", *options,
             'command -v claude; claude --version'],
            cwd=self.home, env=self.env, text=True, capture_output=True,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout.splitlines(),
                         [str(self.launcher), "native fixture version"])

    def assert_preserved(self):
        for name, content in self.seed.items():
            path = self.home / name
            self.assertTrue(path.read_text().startswith(content), name)
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), self.modes[name], name)
        for name, target in self.links.items():
            self.assertTrue((self.home / name).is_symlink(), name)
            self.assertEqual(os.readlink(self.home / name), target)

    def test_real_setup_finalizes_after_late_installers_and_preserves_startup(self):
        native_bytes = (self.native / "claude").read_bytes()
        output = self.setup()
        self.assert_preserved()
        self.assertEqual((self.native / "claude").read_bytes(), native_bytes)
        self.assert_shell_selects_launcher("--noprofile", "--norc", "-c")
        self.assert_shell_selects_launcher("--noprofile", "-ic")
        finalizer = output.index("Claude launcher PATH finalized after harness installation")
        self.assertLess(output.index("late codex installer completed"), finalizer)
        self.assertLess(output.index("late omp installer completed"), finalizer)
        result = subprocess.run(
            ["bash", "--noprofile", "--norc", "-c",
             '. "$HOME/.profile"; command -v claude; claude --version'],
            cwd=self.home, env=self.env, text=True, capture_output=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(),
                         [str(self.launcher), "native fixture version"])
        for name in (".bash_profile", ".bash_login", ".zprofile", ".zlogin"):
            self.assertFalse((self.home / name).exists(), name)

    def test_rerun_keeps_one_final_hook_despite_more_late_path_writes(self):
        self.setup()
        self.setup()
        self.assert_preserved()
        for name in self.seed:
            lines = (self.home / name).read_text().splitlines()
            hooks = [line for line in lines if 'case "$PATH" in' in line
                     and '.local/share/workshop/bin' in line]
            self.assertEqual(len(hooks), 1, name)
            self.assertEqual(lines[-1], hooks[0], name)
        self.assert_shell_selects_launcher("--noprofile", "-ic")

    def test_existing_custom_login_files_are_corrected_in_place(self):
        self.startup(".bash_profile", "LOGIN_USER_VALUE", 0o640)
        self.startup(".bash_login", "SECOND_LOGIN_VALUE", 0o600, symlink=True)
        self.startup(".zlogin", "ZLOGIN_USER_VALUE", 0o644, symlink=True)
        self.setup()
        self.assert_preserved()
        for name in (".bash_profile", ".bash_login", ".zlogin"):
            result = subprocess.run(
                ["bash", "--noprofile", "--norc", "-c",
                 '. "$HOME/$1"; command -v claude; claude --version', "bash", name],
                cwd=self.home, env=self.env, text=True, capture_output=True,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.splitlines(),
                             [str(self.launcher), "native fixture version"], name)

    def test_zsh_noninteractive_login_profile_cannot_shadow_launcher(self):
        self.assertIsNotNone(shutil.which("zsh"), "zsh is required for startup regression tests")
        self.startup(".zprofile", "ZPROFILE_USER_VALUE", 0o640, symlink=True)
        self.setup()
        self.assert_preserved()
        result = subprocess.run(
            ["zsh", "-lc", 'command -v claude; claude --version'],
            cwd=self.home, env=dict(self.env, ZDOTDIR=str(self.home)),
            text=True, capture_output=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(),
                         [str(self.launcher), "native fixture version"])


unittest.main(verbosity=2)
PY
