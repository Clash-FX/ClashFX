#!/usr/bin/env python3
"""Build the bundled mihomo core with ClashFX's temporary upstream fixes.

Keep the workaround small and fail closed when the pinned dependency changes so
an upstream update cannot silently drop or misapply it.
"""

from __future__ import annotations

import hashlib
import os
import pathlib
import shutil
import stat
import subprocess
import tempfile
from contextlib import contextmanager
from typing import Iterator


SING_MODULE = "github.com/metacubex/sing"
EXPECTED_SING_VERSION = "v0.5.7"
MIHOMO_MODULE = "github.com/metacubex/mihomo"
EXPECTED_MIHOMO_VERSION = "v1.19.24"
MODULE_ROOT = pathlib.Path(__file__).resolve().parent
ORIGINAL_IS_CLOSED = (
    "return IsMulti(err, io.EOF, net.ErrClosed, io.ErrClosedPipe, os.ErrClosed, "
    "syscall.EPIPE, syscall.ECONNRESET, syscall.ENOTCONN)"
)
PATCHED_IS_CLOSED = (
    "return IsMulti(err, io.EOF, net.ErrClosed, io.ErrClosedPipe, os.ErrClosed, "
    "syscall.EPIPE, syscall.ECONNRESET, syscall.ENOTCONN, syscall.ENOTSOCK, "
    "syscall.EBADF)"
)
ORIGINAL_URL_TEST = """func (u *URLTest) URLTest(ctx context.Context, url string, expectedStatus utils.IntRanges[uint16]) (map[string]uint16, error) {
	return u.GroupBase.URLTest(ctx, u.testUrl, expectedStatus)
}"""
PATCHED_URL_TEST = """func (u *URLTest) URLTest(ctx context.Context, url string, expectedStatus utils.IntRanges[uint16]) (map[string]uint16, error) {
	// Now() can run while the candidates are still being tested and cache a
	// partial choice for ten seconds. Clear that value once all results are in
	// so the next selection uses the complete result set and tolerance.
	u.fastSingle.Reset()
	defer u.fastSingle.Reset()
	return u.GroupBase.URLTest(ctx, u.testUrl, expectedStatus)
}"""
QUEUE_SOURCE_SHA256 = "dce56d5c8e57c4a5df35c2960ced52ee19b4441864e9908692c3321be84e71de"
ORIGINAL_QUEUE_POP = """func (q *Queue[T]) Pop() (head T) {
	if len(q.items) == 0 {
		return
	}

	q.lock.Lock()
	head = q.items[0]
	q.items = q.items[1:]
	q.lock.Unlock()
	return head
}"""
PATCHED_QUEUE_POP = """func (q *Queue[T]) Pop() (head T) {
	q.lock.Lock()
	defer q.lock.Unlock()
	if len(q.items) == 0 {
		return
	}

	head = q.items[0]
	q.items = q.items[1:]
	return head
}"""
ORIGINAL_QUEUE_LAST = """func (q *Queue[T]) Last() (last T) {
	if len(q.items) == 0 {
		return
	}

	q.lock.RLock()
	last = q.items[len(q.items)-1]
	q.lock.RUnlock()
	return last
}"""
PATCHED_QUEUE_LAST = """func (q *Queue[T]) Last() (last T) {
	q.lock.RLock()
	defer q.lock.RUnlock()
	if len(q.items) == 0 {
		return
	}

	return q.items[len(q.items)-1]
}"""
CACHEFILE_SOURCE_SHA256 = {
    "component/profile/cachefile/cache.go": "42dff0ec9817dd1abef1d50192e99e012b34cf49b0a6fab897b8fcec2061dc95",
    "component/profile/cachefile/storage.go": "7d4d232edd115890457605a217eb0a790d1a68d13084f8b0e92903ad6c1be4dc",
    "component/profile/cachefile/etag.go": "6b98227e3a921db09563b1713d3b533440aa1a656d8154142b14517efca19ab9",
    "component/profile/cachefile/subscriptioninfo.go": "b5ed8f0f109ec8f28c70309800fc6b6c1bce8ff577fc323fd900e6cff9f1a24c",
    "component/profile/cachefile/fakeip.go": "1f98752ff24228483d6a52bc9902d5607762a6a0990d203a9e7bf35acf70ebbc",
}


def _replace_once(source: str, original: str, replacement: str, label: str) -> str:
    count = source.count(original)
    if count != 1:
        raise RuntimeError(f"Expected one {label} in pinned Mihomo source; found {count}")
    return source.replace(original, replacement, 1)


def _add_cache_read_lock(source: str, signature: str, receiver: str = "c") -> str:
    insertion = (
        f"{signature}\n"
        f"\t{receiver}.mu.RLock()\n"
        f"\tdefer {receiver}.mu.RUnlock()"
    )
    return _replace_once(source, signature, insertion, signature)


def _patch_cachefile_lifecycle(mihomo_root: pathlib.Path) -> None:
    cachefile_root = mihomo_root / "component" / "profile" / "cachefile"
    originals: dict[str, str] = {}
    for relative_path, expected_hash in CACHEFILE_SOURCE_SHA256.items():
        source_path = mihomo_root / relative_path
        original = source_path.read_text(encoding="utf-8")
        actual_hash = hashlib.sha256(original.encode("utf-8")).hexdigest()
        if actual_hash != expected_hash:
            raise RuntimeError(
                f"Pinned CacheFile source changed at {source_path}; "
                "review the ClashFX cache lifecycle overlay"
            )
        originals[relative_path] = original
    for relative_path in originals:
        source_path = mihomo_root / relative_path
        os.chmod(source_path, source_path.stat().st_mode | stat.S_IWUSR)
    os.chmod(
        cachefile_root,
        cachefile_root.stat().st_mode | stat.S_IWUSR | stat.S_IXUSR,
    )

    cache_path = "component/profile/cachefile/cache.go"
    source = originals[cache_path]
    source = _replace_once(
        source,
        "// CacheFile store and update the cache file",
        "// CacheFile stores and updates the cache file. Every DB user must hold\n// mu.RLock for the complete operation; Close and Reopen take mu exclusively.",
        "CacheFile lifecycle comment",
    )
    source = _replace_once(
        source,
        "type CacheFile struct {\n\tDB *bbolt.DB\n}",
        "type CacheFile struct {\n\tmu     sync.RWMutex\n\tDB     *bbolt.DB\n\tclosed bool\n}",
        "CacheFile fields",
    )
    source = _add_cache_read_lock(
        source,
        "func (c *CacheFile) SetSelected(group, selected string) {",
    )
    source = _add_cache_read_lock(
        source,
        "func (c *CacheFile) SelectedMap() map[string]string {",
    )
    source = _replace_once(
        source,
        "func (c *CacheFile) Close() error {\n\treturn c.DB.Close()\n}",
        """func (c *CacheFile) Close() error {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.DB == nil || c.closed {
		return nil
	}
	err := c.DB.Close()
	c.closed = true
	return err
}

// Reopen replaces the database only while all CacheFile operations are gated.
func (c *CacheFile) Reopen(path string, mode os.FileMode, options *bbolt.Options) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.DB != nil && !c.closed {
		return nil
	}
	db, err := bbolt.Open(path, mode, options)
	if err != nil {
		return err
	}
	c.DB = db
	c.closed = false
	return nil
}""",
        "CacheFile.Close implementation",
    )
    source = _replace_once(
        source,
        "defaultCache = &CacheFile{\n\t\tDB: db,\n\t}",
        "defaultCache = &CacheFile{\n\t\tDB: db,\n\t\tclosed: db == nil,\n\t}",
        "CacheFile initialization",
    )
    source = source.replace("else if c.DB == nil {", "else if c.DB == nil || c.closed {")
    (cachefile_root / "cache.go").write_text(source, encoding="utf-8")

    # These methods access DB directly. Put their complete bodies under the
    # CacheFile read gate so Close and Reopen can take its exclusive side.
    signatures_by_file = {
        "component/profile/cachefile/storage.go": [
            "func (c *CacheFile) GetStorage(key string) []byte {",
            "func (c *CacheFile) SetStorage(key string, data []byte) {",
        ],
        "component/profile/cachefile/etag.go": [
            "func (c *CacheFile) SetETagWithHash(url string, etagWithHash EtagWithHash) {",
            "func (c *CacheFile) GetETagWithHash(key string) (etagWithHash EtagWithHash) {",
        ],
        "component/profile/cachefile/subscriptioninfo.go": [
            "func (c *CacheFile) SetSubscriptionInfo(name string, userInfo string) {",
            "func (c *CacheFile) GetSubscriptionInfo(name string) (userInfo string) {",
        ],
        "component/profile/cachefile/fakeip.go": [
            "func (c *FakeIpStore) GetByHost(host string) (ip netip.Addr, exist bool) {",
            "func (c *FakeIpStore) PutByHost(host string, ip netip.Addr) {",
            "func (c *FakeIpStore) GetByIP(ip netip.Addr) (host string, exist bool) {",
            "func (c *FakeIpStore) PutByIP(ip netip.Addr, host string) {",
            "func (c *FakeIpStore) DelByIP(ip netip.Addr) {",
            "func (c *FakeIpStore) FlushFakeIP() error {",
        ],
    }
    for relative_path, signatures in signatures_by_file.items():
        source = originals[relative_path]
        for signature in signatures:
            receiver = "c.CacheFile" if "FakeIpStore" in signature else "c"
            source = _add_cache_read_lock(source, signature, receiver)
        source = source.replace("if c.DB == nil {", "if c.DB == nil || c.closed {")
        source = source.replace("else if c.DB == nil {", "else if c.DB == nil || c.closed {")
        (mihomo_root / relative_path).write_text(source, encoding="utf-8")

    storage_path = mihomo_root / "component/profile/cachefile/storage.go"
    source = storage_path.read_text(encoding="utf-8")
    source = _replace_once(
        source,
        "\t\t\tc.DeleteStorage(key)",
        "\t\t\tc.deleteStorageLocked(key)",
        "corrupt-storage deletion",
    )
    source = _replace_once(
        source,
        """func (c *CacheFile) DeleteStorage(key string) {
	if c.DB == nil || c.closed {
		return
	}
	err := c.DB.Batch(func(t *bbolt.Tx) error {
		bucket := t.Bucket(bucketStorage)
		if bucket == nil {
			return nil
		}
		return bucket.Delete([]byte(key))
	})
	if err != nil {
		log.Warnln("[CacheFile] delete cache from %s failed: %s", c.DB.Path(), err.Error())
	}
}""",
        """func (c *CacheFile) DeleteStorage(key string) {
	c.mu.RLock()
	defer c.mu.RUnlock()
	c.deleteStorageLocked(key)
}

func (c *CacheFile) deleteStorageLocked(key string) {
	if c.DB == nil || c.closed {
		return
	}
	err := c.DB.Batch(func(t *bbolt.Tx) error {
		bucket := t.Bucket(bucketStorage)
		if bucket == nil {
			return nil
		}
		return bucket.Delete([]byte(key))
	})
	if err != nil {
		log.Warnln("[CacheFile] delete cache from %s failed: %s", c.DB.Path(), err.Error())
	}
}""",
        "DeleteStorage implementation",
    )
    storage_path.write_text(source, encoding="utf-8")

    fakeip_path = mihomo_root / "component/profile/cachefile/fakeip.go"
    source = fakeip_path.read_text(encoding="utf-8")
    source = _replace_once(
        source,
        "func (c *FakeIpStore) FlushFakeIP() error {\n\tc.CacheFile.mu.RLock()\n\tdefer c.CacheFile.mu.RUnlock()\n",
        "func (c *FakeIpStore) FlushFakeIP() error {\n\tc.CacheFile.mu.RLock()\n\tdefer c.CacheFile.mu.RUnlock()\n\tif c.DB == nil || c.closed {\n\t\treturn nil\n\t}\n",
        "FlushFakeIP closed-cache guard",
    )
    fakeip_path.write_text(source, encoding="utf-8")

    subprocess.check_call(
        [
            "gofmt",
            "-w",
            str(cachefile_root / "cache.go"),
            str(cachefile_root / "storage.go"),
            str(cachefile_root / "etag.go"),
            str(cachefile_root / "subscriptioninfo.go"),
            str(cachefile_root / "fakeip.go"),
        ]
    )


def _patch_queue_races(mihomo_root: pathlib.Path) -> None:
    queue_path = mihomo_root / "common" / "queue" / "queue.go"
    original = queue_path.read_text(encoding="utf-8")
    actual_hash = hashlib.sha256(original.encode("utf-8")).hexdigest()
    if actual_hash != QUEUE_SOURCE_SHA256:
        raise RuntimeError(
            f"Pinned queue source changed at {queue_path}; "
            "review the ClashFX queue race overlay"
        )

    source = _replace_once(original, ORIGINAL_QUEUE_POP, PATCHED_QUEUE_POP, "Queue.Pop")
    source = _replace_once(source, ORIGINAL_QUEUE_LAST, PATCHED_QUEUE_LAST, "Queue.Last")
    os.chmod(queue_path, queue_path.stat().st_mode | stat.S_IWUSR)
    queue_path.write_text(source, encoding="utf-8")
    subprocess.check_call(["gofmt", "-w", str(queue_path)])


def _remove_tree(path: pathlib.Path) -> None:
    if not path.exists():
        return
    for root, directories, files in os.walk(path):
        root_path = pathlib.Path(root)
        os.chmod(root_path, root_path.stat().st_mode | stat.S_IWUSR | stat.S_IXUSR)
        for name in directories + files:
            child = root_path / name
            os.chmod(child, child.stat().st_mode | stat.S_IWUSR)
    shutil.rmtree(path)


def _resolve_module(module: str, expected_version: str) -> pathlib.Path:
    subprocess.check_call(
        ["go", "mod", "download", module],
        cwd=MODULE_ROOT,
    )
    module_info = subprocess.check_output(
        ["go", "list", "-m", "-f", "{{.Version}}\n{{.Dir}}", module],
        text=True,
        cwd=MODULE_ROOT,
    ).splitlines()
    if len(module_info) != 2:
        raise RuntimeError(f"Unable to resolve {module}")

    version, module_dir = module_info
    if version != expected_version:
        raise RuntimeError(
            f"Review the ClashFX core overlay before updating {module}: "
            f"expected {expected_version}, found {version}"
        )
    return pathlib.Path(module_dir)


@contextmanager
def core_modfile() -> Iterator[str]:
    # A fresh CI runner has the version in go.sum but no extracted module
    # directory yet. Download the pinned module before asking Go for its path.
    sing_source_module = _resolve_module(SING_MODULE, EXPECTED_SING_VERSION)
    mihomo_source_module = _resolve_module(MIHOMO_MODULE, EXPECTED_MIHOMO_VERSION)

    sing_source = sing_source_module / "common" / "exceptions" / "error.go"
    sing_original = sing_source.read_text(encoding="utf-8")
    if sing_original.count(ORIGINAL_IS_CLOSED) != 1:
        raise RuntimeError(
            f"The expected IsClosed implementation changed in {sing_source}; "
            "review the ClashFX overlay"
        )

    mihomo_source = mihomo_source_module / "adapter" / "outboundgroup" / "urltest.go"
    mihomo_original = mihomo_source.read_text(encoding="utf-8")
    if mihomo_original.count(ORIGINAL_URL_TEST) != 1:
        raise RuntimeError(
            f"The expected URLTest implementation changed in {mihomo_source}; "
            "review the ClashFX overlay"
        )

    temp_dir = pathlib.Path(tempfile.mkdtemp(prefix="clashfx-core-workaround-"))
    workaround_root = MODULE_ROOT / ".clashfx-core-workaround"
    if workaround_root.exists():
        _remove_tree(temp_dir)
        raise RuntimeError(
            f"Temporary core workaround already exists at {workaround_root}; "
            "another build may be running"
        )
    try:
        workaround_root.mkdir()
        sing_replacement_module = workaround_root / "sing"
        shutil.copytree(sing_source_module, sing_replacement_module)
        sing_replacement = sing_replacement_module / "common" / "exceptions" / "error.go"
        os.chmod(sing_replacement, sing_replacement.stat().st_mode | stat.S_IWUSR)
        sing_replacement.write_text(
            sing_original.replace(ORIGINAL_IS_CLOSED, PATCHED_IS_CLOSED),
            encoding="utf-8",
        )

        mihomo_replacement_module = workaround_root / "mihomo"
        shutil.copytree(mihomo_source_module, mihomo_replacement_module)
        mihomo_replacement = (
            mihomo_replacement_module / "adapter" / "outboundgroup" / "urltest.go"
        )
        os.chmod(mihomo_replacement, mihomo_replacement.stat().st_mode | stat.S_IWUSR)
        mihomo_replacement.write_text(
            mihomo_original.replace(ORIGINAL_URL_TEST, PATCHED_URL_TEST),
            encoding="utf-8",
        )
        _patch_cachefile_lifecycle(mihomo_replacement_module)
        _patch_queue_races(mihomo_replacement_module)

        modfile = temp_dir / "clashfx.mod"
        modfile.write_text(
            (MODULE_ROOT / "go.mod").read_text(encoding="utf-8") +
            f"\nreplace {SING_MODULE} => ./.clashfx-core-workaround/sing\n" +
            f"replace {MIHOMO_MODULE} => ./.clashfx-core-workaround/mihomo\n",
            encoding="utf-8",
        )
        shutil.copy2(MODULE_ROOT / "go.sum", temp_dir / "clashfx.sum")
        yield str(modfile)
    finally:
        _remove_tree(temp_dir)
        _remove_tree(workaround_root)
