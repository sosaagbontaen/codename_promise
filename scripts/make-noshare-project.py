#!/usr/bin/env python3
"""Writes CodenamePromise-NoShare.xcodeproj: the app without the share extension or its App Group.

For installing on a phone from a Mac whose Xcode isn't signed into an Apple account. The share
extension needs a provisioning profile Xcode can only create while signed in; everything else,
including the Mac inbox, works with the profile already on disk. Generated, never committed.
"""
import os, re, shutil

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
src = os.path.join(root, "CodenamePromise.xcodeproj")
dst = os.path.join(root, "CodenamePromise-NoShare.xcodeproj")
shutil.rmtree(dst, ignore_errors=True)
shutil.copytree(src, dst, ignore=shutil.ignore_patterns("xcuserdata", "*.xcuserstate"))

p = os.path.join(dst, "project.pbxproj")
s = open(p).read()
# The app stops embedding and depending on the extension...
s = s.replace("\t\t\t\t1A0000000000000000000043 /* DumpNotesShare.appex in Embed Foundation Extensions */,\n", "")
s = s.replace("\t\t\t\t1A0000000000000000000048 /* PBXTargetDependency */,\n", "")
# ...and from the scheme's point of view the target no longer exists.
s = s.replace("\t\t\t\t1A0000000000000000000041 /* DumpNotesShare */,\n\t\t\t);\n\t\t};", "\t\t\t);\n\t\t};")
# No App Group on the app.
s = s.replace("\t\t\t\tCODE_SIGN_ENTITLEMENTS = Config/App.entitlements;\n", "")
assert "App.entitlements" not in s and "48 /* PBXTargetDependency */,\n" not in s
open(p, "w").write(s)

# The shared scheme names its project by file name, so point it at this one.
scheme = os.path.join(dst, "xcshareddata", "xcschemes", "CodenamePromise.xcscheme")
x = open(scheme).read().replace("container:CodenamePromise.xcodeproj", "container:CodenamePromise-NoShare.xcodeproj")
open(scheme, "w").write(x)
print(dst)
