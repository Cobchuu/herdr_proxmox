#!/usr/bin/env python3
"""Test-only Herdr protocol double with persistent real PTYs and child agents.

This proves the gateway's protocol and process boundary, never vendor semantics.
Every child and checkout belongs to the disposable fixture supplied by the test.
"""
import json
import os
from pathlib import Path
import shlex
import signal
import socket
import subprocess
import sys
import time


def agent(marker):
    import tty
    tty.setraw(sys.stdin.fileno())
    Path(marker).write_text(str(os.getpid()))
    for line in sys.stdin:
        if line.strip() == 'exit':
            return


class Daemon:
    def __init__(self, root):
        self.root = root
        self.panes, self.agents = {}, {}
        self.running = True
        self.sequence = 0

    def drain(self):
        for pane in self.panes.values():
            try:
                while os.read(pane['master'], 65536):
                    pass
            except (OSError, BlockingIOError):
                pass

    def wait(self, predicate):
        until = time.monotonic() + 8
        while time.monotonic() < until:
            self.drain()
            if predicate():
                return
            time.sleep(.02)
        raise RuntimeError('The test runtime child did not become ready.')

    def shell(self, cwd, environment, workspace=None):
        import pty
        import fcntl
        import termios
        self.sequence += 1
        workspace = workspace or 'w' + str(self.sequence)
        pane_id = workspace + ':p' + str(self.sequence)
        master, slave = pty.openpty()
        def terminal():
            os.setsid()
            fcntl.ioctl(slave, termios.TIOCSCTTY, 0)
        process = subprocess.Popen(['bash', '--noprofile', '--norc', '-i'], cwd=cwd,
            env=dict(os.environ, TERM='xterm', **environment), stdin=slave, stdout=slave,
            stderr=slave, preexec_fn=terminal)
        os.close(slave)
        os.set_blocking(master, False)
        self.panes[pane_id] = dict(process=process, master=master, cwd=cwd)
        self.wait(lambda: os.tcgetpgrp(master) == process.pid)
        return dict(root_pane=dict(pane_id=pane_id), workspace=dict(workspace_id=workspace),
                    tab=dict(workspace_id=workspace))

    def close(self, identity):
        pane = self.panes.pop(identity)
        try:
            foreground = os.tcgetpgrp(pane['master'])
            if foreground != pane['process'].pid:
                os.killpg(foreground, signal.SIGTERM)
        except ProcessLookupError:
            pass
        pane['process'].send_signal(signal.SIGHUP)
        try:
            pane['process'].wait(timeout=3)
        except subprocess.TimeoutExpired:
            pane['process'].kill()
            pane['process'].wait(timeout=3)
        os.close(pane['master'])

    def call(self, args):
        with (self.root / 'calls.jsonl').open('a') as stream:
            stream.write(json.dumps(args) + '\n')
        def value(flag, default=None):
            return args[args.index(flag) + 1] if flag in args else default
        command = tuple(args[:2])
        if command == ('api', 'schema'):
            return {'schemas': {'success_response': {'$defs': {'AgentInfo': {'properties': {
                key: {} for key in ('name', 'pane_id', 'agent', 'agent_status')}}}}}}
        if command == ('worktree', 'create'):
            subprocess.run(['git', '-c', 'core.hooksPath=/dev/null', '-C', value('--cwd'),
                'worktree', 'add', '-b', value('--branch'), value('--path')], check=True, capture_output=True)
        if command in (('workspace', 'create'), ('worktree', 'create'), ('tab', 'create')):
            environment = dict(args[index + 1].split('=', 1) for index, argument in enumerate(args) if argument == '--env')
            return self.shell(value('--path') or value('--cwd'), environment, value('--workspace'))
        if command == ('pane', 'close'):
            self.close(args[2])
            return {}
        if command == ('pane', 'process-info'):
            pane = self.panes[value('--pane')]
            foreground = os.tcgetpgrp(pane['master'])
            return dict(process_info=dict(shell_pid=pane['process'].pid,
                foreground_process_group_id=foreground, foreground_processes=[dict(pid=foreground)]))
        if command == ('pane', 'run'):
            os.write(self.panes[args[2]]['master'], (args[3] + '\n').encode())
            self.drain()
            return {}
        if command == ('agent', 'start'):
            pane_id = value('--pane')
            marker = self.root / ('agent-' + str(self.sequence))
            self.call(['pane', 'run', pane_id, shlex.join([sys.executable, __file__, '--agent', str(marker)])])
            self.wait(marker.exists)
            self.agents[args[2]] = dict(name=args[2], pane_id=pane_id, agent=value('--kind'),
                agent_status='idle', interactive_ready=True, agent_session={'value': marker.name})
            return dict(agent=self.agents[args[2]])
        if command == ('agent', 'get'):
            return dict(agent=self.agents[args[2]])
        if command == ('agent', 'list'):
            return dict(agents=list(self.agents.values()))
        if command == ('agent', 'prompt'):
            return dict(agent=self.agents[args[2]])
        if command == ('test', 'stop'):
            self.running = False
            return {}
        raise ValueError('The test daemon does not implement ' + ' '.join(args[:2]))


def serve(path, root):
    daemon = Daemon(Path(root))
    listener = socket.socket(socket.AF_UNIX)
    listener.bind(path)
    listener.listen()
    try:
        while daemon.running:
            peer, _ = listener.accept()
            with peer, peer.makefile('r') as stream:
                try:
                    result = dict(result=daemon.call(json.loads(stream.readline())))
                except Exception as error:
                    result = dict(error=str(error))
                peer.sendall(json.dumps(result).encode() + b'\n')
    finally:
        for identity in list(daemon.panes):
            daemon.close(identity)
        listener.close()


def client(path, arguments):
    with socket.socket(socket.AF_UNIX) as peer:
        peer.connect(path)
        peer.sendall(json.dumps(arguments).encode() + b'\n')
        with peer.makefile('r') as stream:
            response = stream.readline()
            lost = Path(path).parent / 'drop-start-response'
            if arguments[:2] == ['agent', 'start'] and lost.exists():
                lost.unlink()
                print('Simulated lost response after accepted agent start.', file=sys.stderr)
                raise SystemExit(1)
            print(response, end='')


if __name__ == '__main__':
    if sys.argv[1] == '--daemon':
        serve(sys.argv[2], sys.argv[3])
    elif sys.argv[1] == '--agent':
        agent(sys.argv[2])
    else:
        client(sys.argv[1], sys.argv[2:])
