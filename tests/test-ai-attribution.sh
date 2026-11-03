#!/usr/bin/env bash
# Exercise the shared detector, real Git hook and Claude envelope offline.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export ROOT
python3 - <<'PY'
import importlib.util, json, os, pathlib, subprocess, sys, tempfile
sys.dont_write_bytecode = True
root = pathlib.Path(os.environ['ROOT'])
spec = importlib.util.spec_from_file_location('attribution', root/'Tools/check-ai-attribution.py')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
for text in ['Co-authored-by: Claude <noreply@anthropic.com>',
             'co-AUTHORED-by: Codex <codex@openai.com>',
             'Co-authored-by: GitHub Copilot <copilot@github.com>',
             'Co-authored-by: Gemini', 'Generated with Claude Code',
             '🤖 Generated with [Claude Code](https://claude.ai/code)',
             'Written by Codex.', 'Assisted by Gemini']:
    assert m.detected(text), text
for text in ['Discuss Claude configuration', 'Co-authored-by: Jane <jane@example.com>',
             'Use Copilot for this example', 'Claude fixed the bug',
             'Co-authored-by: Claude Smith <claude@example.com>']:
    assert m.detected(text) is None, text
with tempfile.TemporaryDirectory() as tmp:
    repo=pathlib.Path(tmp)/'repo with spaces'; repo.mkdir()
    def git(*args, **kwargs):
        return subprocess.run(['git','-C',str(repo),*args],capture_output=True,text=True,**kwargs)
    assert git('init').returncode == 0
    git('config','user.name','Test'); git('config','user.email','test@example.com')
    git('config','core.hooksPath',str(root/'Tools/hooks'))
    message=repo/'message'; credit='Fix bug\n\nCo-authored-by: Claude <noreply@anthropic.com>\n'
    message.write_text(credit)
    result=git('commit','--allow-empty','-F',str(message))
    assert result.returncode != 0 and 'Remove this assistant credit line' in result.stdout+result.stderr, result
    assert git('rev-parse','--verify','HEAD').returncode != 0
    assert message.read_text() == credit
    for command in ["gh pr create --title 'Generated with Codex' --body ok",
                    "gh pr edit 12 --body 'Co-authored-by: Claude <noreply@anthropic.com>'",
                    'gh pr create --body-file message',
                    "gh pr edit --body-file=message",
                    "gh pr create -tTitle -b'Generated with Codex'"]:
        assert m.check_command(command,repo)==1, command
    for command in ['gh pr create --body "$BODY"', 'gh pr create --body-file missing',
                    'gh pr create --body-file -', 'gh pr create -Rowner/repo --body ok', 'curl example.com',
                    'gh pr create --body ok | cat',
                    "if false; then\ngh pr create --body 'Generated with Claude'\nfi"]:
        assert m.check_command(command,repo)==2, command
    assert m.check_command("gh pr create --body 'Discuss Claude'",repo)==0
    os.mkfifo(repo/'pipe')
    assert m.check_command('gh pr create --body-file pipe',repo)==2
    assert m.check_command('gh pr create --body "$(touch should-not-exist)"',repo)==2
    assert not (repo/'should-not-exist').exists()
    assert m.check_command("gh pr create --title '&&' --body 'Generated with Claude'",repo)==1
    assert m.check_command("printf '%s' ';' gh pr create --body 'Generated with Claude'",repo)==2
    payload={'cwd':str(repo),'tool_input':{'command':'gh pr create --body-file message'}}
    result=subprocess.run(['bash',str(root/'Tools/claude-attribution-guard.sh')],input=json.dumps(payload),capture_output=True,text=True)
    assert result.returncode==0
    assert json.loads(result.stdout)['hookSpecificOutput']['permissionDecision']=='deny'
    git('config','workshop.blockAIAttribution','false')
    assert git('commit','--allow-empty','-F',str(message)).returncode==0
    assert m.check_command('gh pr create --body-file message',repo)==0
    # Policy follows cd and input cwd rather than the hook's launch directory.
    assert m.check_command(f"cd '{repo}' && gh pr create --body-file message",pathlib.Path(tmp))==0
    result=subprocess.run(['bash',str(root/'Tools/claude-attribution-guard.sh')],input=json.dumps(payload),capture_output=True,text=True)
    assert result.returncode==0 and not result.stdout
    result=subprocess.run(['bash',str(root/'Tools/claude-attribution-guard.sh')],input='{',capture_output=True,text=True)
    assert result.returncode==0 and not result.stdout
print('PASS: detector, real commit rejection, unchanged text, opt-out, PR predicate and Claude adapter')
PY
