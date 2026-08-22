"""Audit tracker: which paths were audited, when, and against which commit.

Ships inside the ``audit-and-fix`` skill (task-queue precedent: one symlink
delivers skill and engine together). Import as ``audit_tracker.*`` after the
skill's ``tracker.py`` launcher has bootstrapped ``sys.path`` — never as
``devtools.audit_tracker``, and never via a mount-named path.
"""
