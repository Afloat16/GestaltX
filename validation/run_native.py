import json, os, pathlib, subprocess, sys
root = pathlib.Path(sys.argv[1]).resolve()
os.chdir(root)
sources = ["GestaltX/GestaltDocument.swift", "GestaltX/Capabilities.swift", "GestaltX/DeviceCacheOptions.swift", "GestaltX/MobileGestaltCacheLayout.swift", "GestaltX/Localization.swift", "GestaltX/DevicePlistIdentity.swift", "GestaltX/DeviceBoundPlist.swift", "Shared/SharedPlistInbox.swift", "ShareExtension/ItemProviderLoad.swift", "GestaltX/SharedImportQueue.swift"]
for candidate in ["GestaltX/TemporaryExport.swift", "GestaltX/DirectFileImports.swift", "GestaltX/CoordinatedImportReader.swift", "Shared/PlistReadWorker.swift"]:
    if pathlib.Path(candidate).exists():
        sources.append(candidate)
tests = json.loads(os.environ.get("GX_TESTS", "[]"))
if not tests:
    tests = [str(p) for p in sorted(pathlib.Path("tests").glob("*Tests.swift"))]
for test in tests:
    if test.endswith("/WAPITests.swift"):
        continue
    binary = pathlib.Path(os.environ["RUNNER_TEMP"]) / ("gx-" + pathlib.Path(test).stem)
    print("VALIDATING " + test, flush=True)
    if test.endswith(".m"):
        command = ["clang", "-fobjc-arc", "-fblocks", "-framework", "Foundation", "-I", "GestaltX", "GestaltX/GXCacheDirectory.m", test, "-o", str(binary)]
    else:
        test_sources = [test]
        if test.endswith("/DocumentTests.swift"):
            test_sources.append("tests/WAPITests.swift")
        command = ["swiftc", "-swift-version", "5", "-parse-as-library", *sources, *test_sources, "-o", str(binary)]
    subprocess.run(command, check=True, timeout=180)
    subprocess.run([str(binary)], check=True, timeout=90)
print("PASS: native regressions", flush=True)
