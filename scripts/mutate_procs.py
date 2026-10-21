"""Test oracle for scripts/procs.sh (docs/self-hosting.md, D7): one deliberate break of the helper, run in a copy of the
tree against scripts/check_procs.sh. A break is KILLED when that check prints a FAIL line. Python edits copies of the
helper and runs the shell; it decides nothing about the product.

Usage: python3 scripts/mutate_procs.py [--only NAME,NAME]"""
import concurrent.futures
import pathlib
import shutil
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]

# (name, old, new, what it breaks, equivalent): `old` must occur exactly once in scripts/procs.sh. `equivalent` is a reason
# when the break cannot be seen by a check of the helper (then SURVIVED is the expected answer), else None.
M = [
    ("no-filter", ' | grep -vxF "$(ancestors)"', "", "the ancestors are not dropped: the runner that runs the gate is a leak", None),
    ("filter-everything", 'grep -vxF "$(ancestors)"', "grep -v ^$$", "everything is dropped: a leak is not found", None),
    ("only-self", '_pid=$(sed \'s/^.*) //\' "/proc/$_pid/stat" 2> /dev/null | cut -d\' \' -f2)', "_pid=", "only the asker is an ancestor, not the processes above it", None),
    ("two-levels", '[ "$_depth" -lt 256 ]', '[ "$_depth" -lt 2 ]', "only the asker and its parent are ancestors, not the processes above", None),
    ("no-bound", '&& [ "$_depth" -lt 256 ]', "", "the walk has no bound: a misread parent field loops for ever", "a loop is bounded by the parent field reaching 0 on a well-formed /proc; only a misread field (see not-the-parent) loops, and that break is killed"),
    ("not-the-parent", "cut -d' ' -f2)", "cut -d' ' -f3)", "the process group is read as the parent", None),
    ("zombies-count", '[ "$_state" != Z ]', "true", "a process that has ended and waits to be collected is a leftover", None),
    ("no-stop", '[ "$_pid" -gt 0 ] 2> /dev/null', "true", "the walk does not stop at pid 0 (it would loop on an unreadable /proc entry)", "the walk ends anyway when /proc/PID/stat cannot be read: _pid becomes empty; unobservable on a machine where /proc is readable"),
    ("fixed-string", "grep -vxF", "grep -vx", "the ancestors are patterns, not fixed strings", "a pid is digits only, so a pattern and a fixed string are the same"),
]


def one(m):
    name, old, new, what, equivalent = m
    with tempfile.TemporaryDirectory() as tmp:
        work = pathlib.Path(tmp) / "w"
        shutil.copytree(ROOT, work, ignore=shutil.ignore_patterns(".git", "build", "target"))
        path = work / "scripts" / "procs.sh"
        text = path.read_text()
        if text.count(old) != 1:
            return name, what, f"BAD BREAK: the old text occurs {text.count(old)} times", equivalent
        path.write_text(text.replace(old, new))
        scratch = pathlib.Path(tmp) / "s"
        scratch.mkdir()
        r = subprocess.run(["sh", "scripts/check_procs.sh", str(scratch)], capture_output=True, text=True, cwd=work, timeout=300)
        out = r.stdout + r.stderr
        if "FAIL " in out or r.returncode != 0:
            return name, what, "KILLED", equivalent
        return name, what, "SURVIVED", equivalent


def main():
    only = None
    if "--only" in sys.argv:
        only = set(sys.argv[sys.argv.index("--only") + 1].split(","))
    todo = [m for m in M if only is None or m[0] in only]
    with concurrent.futures.ThreadPoolExecutor(3) as pool:
        results = list(pool.map(one, todo))
    bad = 0
    for name, what, verdict, equivalent in results:
        note = ""
        if verdict == "SURVIVED" and equivalent:
            verdict = "EQUIVALENT"
            note = f"  ({equivalent})"
        elif verdict != "KILLED":
            bad += 1
        print(f"{verdict:10} {name:18} {what}{note}")
    killed = sum(1 for r in results if r[2] == "KILLED")
    print(f"{killed} of {len(results)} breaks killed")
    sys.exit(1 if bad else 0)


main()
