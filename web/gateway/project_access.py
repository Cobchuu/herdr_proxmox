"""Descriptor-anchored access shared by project browsing and discovery.

Every name is opened relative to a directory already pinned by a descriptor.
A concurrent rename cannot redirect an opened ancestor, and a replacement link
is refused before it can become an ancestor. Unsupported platforms fail closed.
"""
from contextlib import contextmanager
import os
from pathlib import Path

ANCHORED_ACCESS = (os.open in os.supports_dir_fd and os.scandir in os.supports_fd
                   and hasattr(os, 'O_NOFOLLOW') and hasattr(os, 'O_DIRECTORY'))


@contextmanager
def open_project(root, relative):
    """Walk from a pinned root handle; never reopen a validated pathname."""
    if not ANCHORED_ACCESS:
        raise ValueError('Secure project browsing requires a Linux gateway.')
    root = Path(root).absolute()
    relative = relative_path(relative)
    descriptors = []
    try:
        descriptor = os.open(root.anchor, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        descriptors.append(descriptor)
        for part in root.parts[1:]:
            descriptor = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=descriptor)
            descriptors.append(descriptor)
        for index, part in enumerate(relative.parts):
            flags = os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK
            if index < len(relative.parts) - 1:
                flags |= os.O_DIRECTORY
            descriptor = os.open(part, flags, dir_fd=descriptor)
            descriptors.append(descriptor)
        yield descriptor
    except OSError as error:
        raise ValueError('Project path is unavailable or contains a symbolic link.') from error
    finally:
        for descriptor in reversed(descriptors):
            os.close(descriptor)


def relative_path(value):
    text = str(value)
    path = Path(value)
    if '\\' in text or '\x00' in text or path.is_absolute() or path.drive or '..' in path.parts or ':' in text:
        raise ValueError('Select a relative path inside the project directory.')
    return path


@contextmanager
def open_directory(parent, name):
    """Pin one child without resolving its name through a pathname ancestor."""
    path = relative_path(name)
    if len(path.parts) != 1:
        raise ValueError('Select one child directory.')
    descriptor = os.open(str(path), os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent)
    try:
        yield descriptor
    finally:
        os.close(descriptor)
