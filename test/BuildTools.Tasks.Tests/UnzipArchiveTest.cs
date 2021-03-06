﻿// Copyright (c) .NET Foundation. All rights reserved.
// Licensed under the Apache License, Version 2.0. See License.txt in the project root for license information.

using System;
using System.IO;
using Microsoft.AspNetCore.BuildTools;
using Xunit;

using ZipArchiveStream = System.IO.Compression.ZipArchive;
using System.IO.Compression;

namespace BuildTools.Tasks.Tests
{
    public class UnzipArchiveTest : IDisposable
    {
        private readonly string _tempDir;

        public UnzipArchiveTest()
        {
            _tempDir = Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString());
            Directory.CreateDirectory(_tempDir);
        }

        [Fact]
        public void UnzipsFile()
        {
            var files = new[]
            {
                "a.txt",
                "dir/b.txt",
            };

            var dest = CreateZip(files);
            var outDir = Path.Combine(_tempDir, "out");

            var task = new UnzipArchive
            {
                File = dest,
                Destination = outDir,
                BuildEngine = new MockEngine(),
            };

            Assert.True(task.Execute(), "Task failed");
            Assert.True(Directory.Exists(outDir), outDir + " does not exist");
            Assert.Equal(files.Length, task.OutputFiles.Length);

            Assert.All(task.OutputFiles,
                f => Assert.True(Path.IsPathRooted(f.ItemSpec), $"Entry {f} should be a fullpath rooted"));

            foreach (var file in files)
            {
                var outFile = Path.Combine(outDir, file);
                Assert.True(File.Exists(outFile), outFile + " does not exist");
            }
        }

        private string CreateZip(string[] files)
        {
            var dest = Path.Combine(_tempDir, "test.zip");

            using (var fileStream = new FileStream(dest, FileMode.Create))
            using (var zipStream = new ZipArchiveStream(fileStream, ZipArchiveMode.Create))
            {
                foreach (var file in files)
                {
                    zipStream.CreateEntry(file);
                }
            }

            return dest;
        }

        public void Dispose()
        {
            Directory.Delete(_tempDir, recursive: true);
        }
    }
}
