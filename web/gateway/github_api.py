"""Bounded GitHub contribution API. Credentials never appear in snapshots/errors.

The gateway and agents currently share a Unix user. File mode 0600 is protection
against other users, not a sandbox against a same-user agent. Publishing is an
administrator operation; a separate identity/broker is needed for OS isolation.
"""
import json
import os
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import re
import threading
from urllib.error import HTTPError
from urllib.parse import urlencode
from urllib.request import Request, urlopen, HTTPRedirectHandler, build_opener

REPOSITORY = re.compile(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+')
MODES = ('direct', 'fork')
# Fine-grained tokens are limited to their resource owner's repositories, so
# they generally cannot open a pull request on another account's repository.
FINE_GRAINED = 'github_pat_'


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None  # Never forward Authorization to another origin.


class GitHubError(ValueError):
    def __init__(self, status):
        self.status = status
        super().__init__({401: 'GitHub credentials are invalid or expired.',
                          403: 'GitHub access was denied or rate limited.',
                          404: 'GitHub repository or pull request is unavailable.',
                          409: 'GitHub head changed; refresh before continuing.',
                          422: 'GitHub rejected the pull request; refresh before retrying.'}.get(
                              status, 'GitHub request failed.'))


class GitHub:
    def __init__(self, path):
        self.path = Path(path)
        self.lock = threading.RLock()
        self.cache = {}

    def configuration(self):
        if not self.path.exists():
            return {}
        if self.path.is_symlink() or self.path.stat().st_size > 16384:
            raise ValueError('Invalid GitHub credential file.')
        if os.name != 'nt' and self.path.stat().st_mode & 0o077:
            raise ValueError('GitHub credential file must have mode 0600.')
        try:
            data = json.loads(self.path.read_text())
        except (OSError, ValueError):
            raise ValueError('GitHub configuration is unreadable.') from None
        if not isinstance(data, dict):
            raise ValueError('Invalid GitHub configuration.')
        if (not isinstance(data.get('token'), str)
                or not re.fullmatch(r'[A-Za-z0-9_]{20,255}', data['token'])):
            raise ValueError('Invalid GitHub credential file.')
        return data

    def snapshot(self):
        data = self.configuration()
        return dict(configured=bool(data.get('token')), login=data.get('login'),
                    repositories=data.get('repositories', []),
                    publication=data.get('publication', {}),
                    credential_isolation='shared_unix_user')

    def publication_settings(self):
        """Per-upstream publication defaults: direct, or through a named fork."""
        return self.configuration().get('publication', {})

    def publication_options(self):
        """Destinations an operator may select for each configured upstream."""
        options = {}
        for upstream, entry in self.publication_settings().items():
            values = [upstream]
            if entry.get('mode') == 'fork' and isinstance(entry.get('publishing_repository'), str):
                values.append(entry['publishing_repository'])
            options[upstream] = values
        return options

    def allow_publishing(self, upstream, publishing):
        """Authorize a write destination: the configured one for this upstream.

        A task records its destination, so without this check a modified task
        record could publish to an unrelated repository.
        """
        self.allow(upstream)
        if publishing == upstream:
            return
        entry = self.publication_settings().get(upstream) or {}
        if entry.get('mode') != 'fork' or entry.get('publishing_repository') != publishing:
            raise ValueError('Repository is not the configured fork for this project.')

    def request(self, path, method='GET', body=None, token=None):
        if not path.startswith('/') or '\\' in path or '..' in path:
            raise ValueError('Invalid GitHub API path.')
        supplied_token = token is not None
        token = token or self.configuration().get('token')
        if not token:
            raise ValueError('Configure GitHub publishing credentials first.')
        headers = {'Authorization': 'Bearer ' + token, 'Accept': 'application/vnd.github+json',
                   'User-Agent': 'herdr-dashboard', 'X-GitHub-Api-Version': '2022-11-28'}
        with self.lock:
            cached = self.cache.get(path) if method == 'GET' and not supplied_token else None
        if cached and cached[0]:
            headers['If-None-Match'] = cached[0]
        payload = json.dumps(body).encode() if body is not None else None
        if payload:
            headers['Content-Type'] = 'application/json'
        try:
            with build_opener(NoRedirect()).open(Request('https://api.github.com' + path,
                    data=payload, headers=headers, method=method), timeout=15) as response:
                content = response.read(1_000_001)
                if len(content) > 1_000_000:
                    raise ValueError('GitHub response exceeds the size limit.')
                # Do not silently label an incomplete check/review list complete.
                if 'rel="next"' in response.headers.get('Link', ''):
                    raise ValueError('GitHub result exceeds the supported page size; inspect it on GitHub.')
                result = json.loads(content)
                if method == 'GET' and not supplied_token:
                    with self.lock:
                        if len(self.cache) >= 256:
                            self.cache.clear()
                        self.cache[path] = (response.headers.get('ETag'), result)
                return result
        except HTTPError as error:
            status = error.code
            error.close()
            if status == 304:
                # Re-read under the lock: a credential change may have cleared it.
                with self.lock:
                    current = self.cache.get(path)
                if current:
                    return current[1]
                raise GitHubError(status) from None
            raise GitHubError(status) from None
        except (OSError, ValueError) as error:
            if isinstance(error, GitHubError):
                raise
            raise ValueError('GitHub response is unavailable, oversized or incomplete.') from None

    @staticmethod
    def same_fork_network(upstream, publishing):
        """True when both repositories belong to one GitHub fork network."""
        if publishing.get('fork') is not True:
            return False
        source = publishing.get('source')
        if not isinstance(source, dict) or not isinstance(source.get('full_name'), str):
            return False
        root = upstream.get('source') if isinstance(upstream.get('source'), dict) else upstream
        name = root.get('full_name')
        return isinstance(name, str) and source['full_name'].lower() == name.lower()

    @staticmethod
    def pr_capability(token):
        """Report compatibility without inferring token permissions from account access.

        Repository push access does not prove a fine-grained token has the
        separate Pull requests write permission. Only publication tests that.
        """
        return 'not_exercised' if token.startswith(FINE_GRAINED) else 'supported'

    def repository_info(self, repository, token):
        info = self.request('/repos/' + repository, token=token)
        return info if isinstance(info, dict) else {}

    def verify_fork(self, upstream, publishing):
        """Re-check a fork destination against the live API, for task overrides."""
        if not REPOSITORY.fullmatch(str(publishing)) or publishing == upstream:
            raise ValueError('Enter the fork as owner/repository.')
        self.allow(upstream)
        if not self.same_fork_network(self.repository_info(upstream, None), self.repository_info(publishing, None)):
            raise ValueError(publishing + ' is not a fork of ' + upstream + '.')
        return True

    def publication_preflight(self, upstream, publishing):
        """Refresh identity/access without claiming that a read proves token write."""
        self.allow_publishing(upstream, publishing)
        config = self.configuration()
        token = config.get('token')
        user = self.request('/user', token=token)  # Explicit token bypasses cached setup evidence.
        login = user.get('login') if isinstance(user, dict) else None
        if not isinstance(login, str) or not re.fullmatch(r'[A-Za-z0-9-]{1,39}', login):
            raise ValueError('GitHub returned an invalid publishing identity.')
        if login.lower() != str(config.get('login', '')).lower():
            raise ValueError('GitHub publishing account changed; configure credentials again.')
        target = self.repository_info(upstream, token)
        destination = target if upstream == publishing else self.repository_info(publishing, token)
        if (str(target.get('full_name', '')).lower() != upstream.lower()
                or str(destination.get('full_name', '')).lower() != publishing.lower()):
            raise ValueError('GitHub repository moved or is unavailable; inspect the publishing destination.')
        permissions = destination.get('permissions')
        if not isinstance(permissions, dict) or permissions.get('push') is not True:
            raise ValueError('GitHub account no longer has push access to ' + publishing + '.')
        if upstream != publishing:
            if not self.same_fork_network(target, destination):
                raise ValueError(publishing + ' is no longer a fork of ' + upstream + '.')
        return dict(login=login, repository=publishing, upstream=upstream,
                    mode='direct' if upstream == publishing else 'fork',
                    account_write='verified', token_write='not_exercised')

    def configure(self, body):
        if not isinstance(body, dict):
            raise ValueError('Expected GitHub configuration fields.')
        token, repositories = body.get('token'), body.get('repositories')
        if not isinstance(token, str) or not re.fullmatch(r'[A-Za-z0-9_]{20,255}', token):
            raise ValueError('Enter a GitHub personal access token.')
        if (not isinstance(repositories, list) or not 1 <= len(repositories) <= 20
                or any(not isinstance(r, str) or not REPOSITORY.fullmatch(r)
                       or any(p in ('.', '..') for p in r.split('/')) for r in repositories)):
            raise ValueError('Allowlist 1–20 repositories as owner/repository.')
        requested = body.get('publication') or {}
        if not isinstance(requested, dict):
            raise ValueError('Invalid publication settings.')
        publication = {}
        for upstream, entry in requested.items():
            if upstream not in repositories:
                raise ValueError('Publication settings must name an allowlisted repository.')
            if not isinstance(entry, dict) or entry.get('mode') not in MODES:
                raise ValueError('Choose direct or fork publication for each repository.')
            if entry['mode'] == 'direct':
                publication[upstream] = dict(mode='direct', publishing_repository=upstream)
                continue
            publishing = entry.get('publishing_repository')
            if (not isinstance(publishing, str) or not REPOSITORY.fullmatch(publishing)
                    or any(p in ('.', '..') for p in publishing.split('/'))):
                raise ValueError('Enter the fork as owner/repository.')
            if publishing == upstream:
                raise ValueError('A fork destination must differ from the upstream repository.')
            publication[upstream] = dict(mode='fork', publishing_repository=publishing)
        user = self.request('/user', token=token)
        if not isinstance(user, dict) or not re.fullmatch(r'[A-Za-z0-9-]{1,39}', str(user.get('login', ''))):
            raise ValueError('GitHub returned an invalid account identity.')
        login = user['login']
        # Resolve every repository once, concurrently: the dashboard gives this
        # call a bounded timeout, and twenty sequential checks could exceed it.
        needed = list(repositories)
        needed += sorted({entry['publishing_repository'] for entry in publication.values()
                          if entry['mode'] == 'fork'} - set(repositories))
        with ThreadPoolExecutor(max_workers=5) as pool:
            resolved = dict(zip(needed, pool.map(lambda name: self.repository_info(name, token), needed)))
        # A fork-mode upstream is read-only here. Requiring push on it would
        # contradict the purpose of contributing through a fork, and the account
        # permission GitHub reports does not prove the token may write anyway.
        upstreams = {name for name, entry in publication.items() if entry['mode'] == 'fork'}
        writers = [name for name in repositories if name not in upstreams]
        writers += [entry['publishing_repository'] for entry in publication.values() if entry['mode'] == 'fork']
        if not all(isinstance(resolved[name].get('permissions'), dict) and resolved[name]['permissions'].get('push')
                   for name in writers):
            raise ValueError('GitHub account needs push access to every repository Herdr publishes to.')
        for upstream in repositories:
            entry = publication.setdefault(upstream, dict(mode='direct', publishing_repository=upstream))
            if entry['mode'] == 'direct':
                entry['verification'] = dict(
                    fork_access='not_applicable', account_write_to_publishing='verified',
                    token_write_capability='not_exercised', upstream_pr_creation='supported')
                continue
            publishing = entry['publishing_repository']
            if not self.same_fork_network(resolved[upstream], resolved[publishing]):
                raise ValueError(publishing + ' is not a fork of ' + upstream + '.')
            # Setup never creates a branch or pull request to prove write access.
            entry['verification'] = dict(
                fork_access='verified', account_write_to_publishing='verified',
                token_write_capability='not_exercised',
                upstream_pr_creation=self.pr_capability(token))
        with self.lock:
            self.path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            temporary = self.path.with_suffix('.tmp')
            # A crash between create and replace must not block configuration.
            temporary.unlink(missing_ok=True)
            descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            try:
                with os.fdopen(descriptor, 'w') as output:
                    json.dump(dict(token=token, repositories=repositories, login=login,
                                   publication=publication), output)
                temporary.replace(self.path)
            finally:
                temporary.unlink(missing_ok=True)
            self.cache.clear()
        return self.snapshot()

    def allow(self, repository):
        if repository not in self.configuration().get('repositories', []):
            raise ValueError('Repository is not allowlisted for GitHub publishing.')

    def find_pull(self, repository, branch, head_owner=None, base=None):
        self.allow(repository)
        # A fork pull request is discovered by its head owner, not the upstream
        # owner; matching only the branch name could attach another account's
        # pull request to this task. Constraining by base keeps a same-named
        # pull request into another branch out of the result set.
        owner = head_owner or repository.split('/')[0]
        query = dict(head=owner + ':' + branch, state='all', per_page=100)
        if base:
            query['base'] = base
        return self.request('/repos/' + repository + '/pulls?' + urlencode(query))
