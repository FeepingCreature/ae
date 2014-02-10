/**
 * File stuff
 *
 * License:
 *   This Source Code Form is subject to the terms of
 *   the Mozilla Public License, v. 2.0. If a copy of
 *   the MPL was not distributed with this file, You
 *   can obtain one at http://mozilla.org/MPL/2.0/.
 *
 * Authors:
 *   Vladimir Panteleev <vladimir@thecybershadow.net>
 */

module ae.sys.file;

import std.array;
import std.conv;
import std.file;
import std.path;
import std.stdio : File;
import std.string;
import std.utf;

// ************************************************************************

version(Windows)
{
	string[] fastListDir(bool recursive = false, bool symlinks=false)(string pathname, string pattern = null)
	{
		import std.c.windows.windows;

		static if (recursive)
			enforce(!pattern, "TODO: recursive fastListDir with pattern");

		string[] result;
		string c;
		HANDLE h;

		c = buildPath(pathname, pattern ? pattern : "*.*");
		WIN32_FIND_DATAW fileinfo;

		h = FindFirstFileW(toUTF16z(c), &fileinfo);
		if (h != INVALID_HANDLE_VALUE)
		{
			scope(exit) FindClose(h);

			do
			{
				// Skip "." and ".."
				if (std.string.wcscmp(fileinfo.cFileName.ptr, ".") == 0 ||
					std.string.wcscmp(fileinfo.cFileName.ptr, "..") == 0)
					continue;

				static if (!symlinks)
				{
					if (fileinfo.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT)
						continue;
				}

				size_t clength = std.string.wcslen(fileinfo.cFileName.ptr);
				string name = std.utf.toUTF8(fileinfo.cFileName[0 .. clength]);
				string path = buildPath(pathname, name);

				static if (recursive)
				{
					if (fileinfo.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY)
					{
						result ~= fastListDir!recursive(path);
						continue;
					}
				}

				result ~= path;
			} while (FindNextFileW(h,&fileinfo) != FALSE);
		}
		return result;
	}
}
else
version (Posix)
{
	private import core.stdc.errno;
	private import core.sys.posix.dirent;

	string[] fastListDir(bool recursive=false, bool symlinks=false)(string pathname, string pattern = null)
	{
		string[] result;
		DIR* h;
		dirent* fdata;

		h = opendir(toStringz(pathname));
		if (h)
		{
			try
			{
				while((fdata = readdir(h)) != null)
				{
					// Skip "." and ".."
					if (!std.c.string.strcmp(fdata.d_name.ptr, ".") ||
						!std.c.string.strcmp(fdata.d_name.ptr, ".."))
							continue;

					static if (!symlinks)
					{
						if (fdata.d_type & DT_LNK)
							continue;
					}

					size_t len = std.c.string.strlen(fdata.d_name.ptr);
					string name = fdata.d_name[0 .. len].idup;
					if (pattern && !globMatch(name, pattern))
						continue;
					string path = buildPath(pathname, name);

					static if (recursive)
					{
						if (fdata.d_type & DT_DIR)
						{
							result ~= fastListDir!(recursive, symlinks)(path);
							continue;
						}
					}

					result ~= path;
				}
			}
			finally
			{
				closedir(h);
			}
		}
		else
		{
			throw new std.file.FileException(pathname, errno);
		}
		return result;
	}
}
else
	static assert(0, "TODO");

// ************************************************************************

string buildPath2(string[] segments...) { return segments.length ? buildPath(segments) : null; }

/// Shell-like expansion of ?, * and ** in path components
DirEntry[] fileList(string pattern)
{
	auto components = cast(string[])array(pathSplitter(pattern));
	foreach (i, component; components[0..$-1])
		if (component.contains("?") || component.contains("*")) // TODO: escape?
		{
			DirEntry[] expansions; // TODO: filter range instead?
			auto dir = buildPath2(components[0..i]);
			if (component == "**")
				expansions = array(dirEntries(dir, SpanMode.depth));
			else
				expansions = array(dirEntries(dir, component, SpanMode.shallow));

			DirEntry[] result;
			foreach (expansion; expansions)
				if (expansion.isDir())
					result ~= fileList(buildPath(expansion.name ~ components[i+1..$]));
			return result;
		}

	auto dir = buildPath2(components[0..$-1]);
	if (!dir || exists(dir))
		return array(dirEntries(dir, components[$-1], SpanMode.shallow));
	else
		return null;
}

/// ditto
DirEntry[] fileList(string pattern0, string[] patterns...)
{
	DirEntry[] result;
	foreach (pattern; [pattern0] ~ patterns)
		result ~= fileList(pattern);
	return result;
}

/// ditto
string[] fastFileList(string pattern)
{
	auto components = cast(string[])array(pathSplitter(pattern));
	foreach (i, component; components[0..$-1])
		if (component.contains("?") || component.contains("*")) // TODO: escape?
		{
			string[] expansions; // TODO: filter range instead?
			auto dir = buildPath2(components[0..i]);
			if (component == "**")
				expansions = fastListDir!true(dir);
			else
				expansions = fastListDir(dir, component);

			string[] result;
			foreach (expansion; expansions)
				if (expansion.isDir())
					result ~= fastFileList(buildPath(expansion ~ components[i+1..$]));
			return result;
		}

	auto dir = buildPath2(components[0..$-1]);
	if (!dir || exists(dir))
		return fastListDir(dir, components[$-1]);
	else
		return null;
}

/// ditto
string[] fastFileList(string pattern0, string[] patterns...)
{
	string[] result;
	foreach (pattern; [pattern0] ~ patterns)
		result ~= fastFileList(pattern);
	return result;
}

// ************************************************************************

import std.datetime;
import std.exception;

deprecated SysTime getMTime(string name)
{
	return timeLastModified(name);
}

void touch(string fn)
{
	if (exists(fn))
	{
		auto now = Clock.currTime();
		setTimes(fn, now, now);
	}
	else
		std.file.write(fn, "");
}

/// Make sure that the path exists (and create directories as necessary).
void ensurePathExists(string fn)
{
	auto path = dirName(fn);
	if (!exists(path))
		mkdirRecurse(path);
}

import ae.utils.text;

/// Forcibly remove a file or directory.
/// If recursive is true, the entire directory is deleted "atomically"
/// (it is first moved/renamed to another location).
void forceDelete()(string fn, bool recursive=false)
{
	version(Windows)
	{
		import std.process : environment;
		import win32.winnt;
		import win32.winbase;

		auto name = fn.baseName();
		fn = fn.absolutePath().longPath();

		auto fnW = toUTF16z(fn);
		auto attr = GetFileAttributesW(fnW);
		enforce(attr != INVALID_FILE_ATTRIBUTES, "GetFileAttributesW error");
		if (attr & FILE_ATTRIBUTE_READONLY)
			SetFileAttributesW(fnW, attr & ~FILE_ATTRIBUTE_READONLY);

		// To avoid zombifying locked directories,
		// try renaming it first. Attempting to delete a locked directory
		// will make it inaccessible.

		bool tryMoveTo(string target)
		{
			target = target.longPath();
			if (target.endsWith(`\`))
				target = target[0..$-1];
			if (target.length && !target.exists)
				return false;

			string newfn;
			do
				newfn = format("%s\\deleted-%s.%s.%s", target, name, thisProcessID, randomString());
			while (newfn.exists);
			auto newfnW = toUTF16z(newfn);
			if (MoveFileW(fnW, newfnW))
			{
				if (attr & FILE_ATTRIBUTE_DIRECTORY)
				{
					foreach (de; newfn.dirEntries(SpanMode.shallow))
						forceDelete(de.name);
					RemoveDirectoryW(newfnW);
				}
				else
					DeleteFileW(newfnW);
				return true;
			}
			return false;
		}

		auto tmp = environment.get("TEMP");
		if (tmp)
			if (tryMoveTo(tmp))
				return;
		if (tryMoveTo(fn[0..7]~"Temp"))
			return;
		if (tryMoveTo(fn.dirName()))
			return;

		return;
	}
	else
	{
		if (recursive)
			fn.removeRecurse();
		else
			if (fn.isDir)
				fn.rmdir();
			else
				fn.remove();
	}
}

/// If fn is a directory, delete it recursively.
/// Otherwise, delete the file fn.
void removeRecurse(string fn)
{
	if (fn.isDir)
		fn.rmdirRecurse();
	else
		fn.remove();
}

bool isHidden()(string fn)
{
	if (baseName(fn).startsWith("."))
		return true;
	version (Windows)
	{
		import win32.winnt;
		if (getAttributes(fn) & FILE_ATTRIBUTE_HIDDEN)
			return true;
	}
	return false;
}

version (Windows)
{
	/// Return a file's unique ID.
	ulong getFileID()(string fn)
	{
		import win32.winnt;
		import win32.winbase;

		auto fnW = toUTF16z(fn);
		auto h = CreateFileW(fnW, FILE_READ_ATTRIBUTES, 0, null, OPEN_EXISTING, 0, HANDLE.init);
		enforce(h!=INVALID_HANDLE_VALUE, new FileException(fn));
		scope(exit) CloseHandle(h);
		BY_HANDLE_FILE_INFORMATION fi;
		enforce(GetFileInformationByHandle(h, &fi), "GetFileInformationByHandle");

		ULARGE_INTEGER li;
		li.LowPart  = fi.nFileIndexLow;
		li.HighPart = fi.nFileIndexHigh;
		auto result = li.QuadPart;
		enforce(result, "Null file ID");
		return result;
	}

	// TODO: return inode number on *nix
}

deprecated alias std.file.getSize getSize2;

/// Using UNC paths bypasses path length limitation when using Windows wide APIs.
string longPath(string s)
{
	version (Windows)
	{
		if (!s.startsWith(`\\`))
			return `\\?\` ~ s.absolutePath().buildNormalizedPath().replace(`/`, `\`);
	}
	return s;
}

/// Link a directory.
/// Uses symlinks on POSIX, and directory junctions on Windows.
version (Windows)
{
	void dirLink()(in char[] original, in char[] link)
	{
		mkdir(link);
		scope(failure) rmdir(link);

		import win32.winbase;
		import win32.windef;
		import win32.winioctl;

		import ae.sys.windows;

		HANDLE hDir = CreateFileW(link.toUTF16z(), GENERIC_WRITE, 0, null, OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_BACKUP_SEMANTICS, null);
		wenforce(hDir && hDir != INVALID_HANDLE_VALUE, "CreateFileW");
		scope(exit) CloseHandle(hDir);

		auto target = `\??\` ~ original.idup.absolutePath();
		if (target[$-1] != '\\')
			target ~= '\\';
		auto targetW = target.toUTF16();

		enum pathOffset =
			REPARSE_DATA_BUFFER.MountPointReparseBuffer            .offsetof +
			REPARSE_DATA_BUFFER.MountPointReparseBuffer._PathBuffer.offsetof;
		static assert(pathOffset == 16);

		// Despite MSDN, two NUL-terminating characters are needed, one for each string.

		auto buf = new ubyte[pathOffset + (targetW.length + 2) * WCHAR.sizeof];
		auto r = cast(REPARSE_DATA_BUFFER*)buf.ptr;

		r.ReparseTag = IO_REPARSE_TAG_MOUNT_POINT;
		r.ReparseDataLength = to!WORD(buf.length - r.MountPointReparseBuffer.offsetof);
		//r.MountPointReparseBuffer.SubstituteNameOffset = 0;
		r.MountPointReparseBuffer.SubstituteNameLength = to!WORD(targetW.length * WCHAR.sizeof);
		r.MountPointReparseBuffer.PrintNameOffset = to!WORD(r.MountPointReparseBuffer.SubstituteNameLength+2);
		r.MountPointReparseBuffer.PrintNameLength = 0;
		r.MountPointReparseBuffer.PathBuffer[0..targetW.length] = targetW;

		DWORD dwRet; // Needed despite MSDN
		DeviceIoControl(hDir, FSCTL_SET_REPARSE_POINT, buf.ptr, buf.length.to!DWORD(), null, 0, &dwRet, null).wenforce("DeviceIoControl");
	}
}
else
	alias std.file.symlink dirLink;

version (unittest) static import ae.sys.windows;

unittest
{
	mkdir("a"); scope(exit) rmdir("a");
	touch("a/f"); scope(exit) remove("a/f");
	dirLink("a", "b"); scope(exit) rmdir("b");
	assert("b".isSymlink());
	assert("b/f".exists());
}

version (Windows)
{
	void hardLink()(string src, string dst)
	{
		import win32.w32api;

		static assert(_WIN32_WINNT >= 0x501, "CreateHardLinkW not available for target Windows platform. Specify -version=WindowsXP");

		import win32.winnt;
		import win32.winbase;

		enforce(CreateHardLinkW(toUTF16z(dst), toUTF16z(src), null), new FileException(dst));
	}
}
version (Posix)
{
	void hardLink()(string src, string dst)
	{
		import core.sys.posix.unistd;
		enforce(link(toUTFz!(const char*)(src), toUTFz!(const char*)(dst)) == 0, "link() failed: " ~ dst);
	}
}

/// Uses UNC paths to open a file.
/// Requires https://github.com/D-Programming-Language/phobos/pull/1888
File openFile()(string fn, string mode)
{
	File f;
	static if (is(typeof(&f.windowsHandleOpen)))
	{
		import win32.winnt;
		import win32.winbase;
		import ae.sys.windows;

		string winMode;
		foreach (c; mode)
			switch (c)
			{
				case 'r':
				case 'w':
				case 'a':
				case '+':
					winMode ~= c;
					break;
				case 'b':
				case 't':
					break;
				default:
					assert(false, "Unknown character in mode");
			}
		DWORD access, creation;
		bool append;
		switch (winMode)
		{
			case "r" : access = GENERIC_READ                ; creation = OPEN_EXISTING; break;
			case "r+": access = GENERIC_READ | GENERIC_WRITE; creation = OPEN_EXISTING; break;
			case "w" : access =                GENERIC_WRITE; creation = OPEN_ALWAYS  ; break;
			case "w+": access = GENERIC_READ | GENERIC_WRITE; creation = OPEN_ALWAYS  ; break;
			case "a" : access =                GENERIC_WRITE; creation = OPEN_ALWAYS  ; append = true; break;
			case "a+": assert(false, "Not implemented"); // requires two file pointers
			default: assert(false, "Bad file mode: " ~ mode);
		}

		auto pathW = toUTF16z(longPath(fn));
		auto h = CreateFileW(pathW, GENERIC_READ, FILE_SHARE_READ, null, OPEN_EXISTING, 0, HANDLE.init);
		wenforce(h != INVALID_HANDLE_VALUE);

		if (append)
			h.SetFilePointerEx(largeInteger(0), null, FILE_END);

		f.windowsHandleOpen(h, mode);
	}
	else
		f.open(fn, mode);
	return f;
}

ubyte[16] mdFile()(string fn)
{
	import std.digest.md;

	MD5 context;
	context.start();

	auto f = openFile(fn, "rb");
	static ubyte[64 * 1024] buffer;
	while (true)
	{
		auto readBuffer = f.rawRead(buffer);
		if (!readBuffer.length)
			break;
		context.put(cast(ubyte[])readBuffer);
	}
	f.close();

	ubyte[16] digest = context.finish();
	return digest;
}

/// Read a File (which might be a stream) into an array
void[] readFile(File f)
{
	ubyte[] result;
	static ubyte[64 * 1024] buffer;
	while (true)
	{
		auto readBuffer = f.rawRead(buffer);
		if (!readBuffer.length)
			break;
		result ~= readBuffer;
	}
	return result;
}

// ****************************************************************************

import std.process : thisProcessID;
import std.traits;
import std.typetuple;
import ae.utils.meta;

/// Wrap an operation which creates a file or directory,
/// so that it is created safely and, for files, atomically
/// (by performing the underlying operation to a temporary
/// location, then renaming the completed file/directory to
/// the actual target location). targetName specifies the name
/// of the parameter containing the target file/directory.
auto safeUpdate(alias impl, string targetName = "target")(staticMap!(Unqual, ParameterTypeTuple!impl) args)
{
	enum targetIndex = findParameter!(impl, targetName);
	auto target = args[targetIndex];
	auto temp = "%s.%s.temp".format(target, thisProcessID);
	if (temp.exists) temp.removeRecurse();
	scope(failure) if (temp.exists) temp.removeRecurse();
	scope(success) rename(temp, target);
	args[targetIndex] = temp;
	return impl(args);
}

/// Wrap an operation so that it is skipped entirely
/// if the target already exists. Implies safeUpdate.
void obtainUsing(alias impl, string targetName = "target")(ParameterTypeTuple!impl args)
{
	auto target = args[findParameter!(impl, targetName)];
	if (target.exists)
		return;
	safeUpdate!(impl, targetName)(args);
}

/// Create a file, or replace an existing file's contents
/// atomically.
alias safeUpdate!(std.file.write, "name") atomicWrite;
deprecated alias safeWrite = atomicWrite;

/// Copy a file, or replace an existing file's contents
/// with another file's, atomically.
alias safeUpdate!(std.file.copy, "to") atomicCopy;

/// Try to rename; copy/delete if rename fails
void move(string src, string dst)
{
	try
		src.rename(dst);
	catch (Exception e)
	{
		atomicCopy(src, dst);
		src.remove();
	}
}
