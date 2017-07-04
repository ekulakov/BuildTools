// Copyright (c) .NET Foundation. All rights reserved.
// Licensed under the Apache License, Version 2.0. See License.txt in the project root for license information.

using System;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using Microsoft.Build.Framework;

namespace Internal.AspNetCore.Sdk
{
    /// <summary>
    /// Resolves SDKs from the KoreBuild folder using the korebuild-lock.txt file to find the right version of KoreBuild.
    /// </summary>
    public class KoreBuildSdksResolver : SdkResolver
    {
        private static readonly string[] _supportedSdks = new[] { "Internal.AspNetCore.Sdk", "KoreBuild.RepoTasks.Sdk" };

        private static readonly string KoreBuildHome = InitializeKoreBuildHome();

        public override string Name => "KoreBuild.Sdks";

        public override int Priority => 5000;

        public override SdkResult Resolve(SdkReference sdkReference, SdkResolverContext resolverContext, SdkResultFactory factory)
        {
            try
            {
                return ResolveImpl(sdkReference, resolverContext, factory);
            }
            catch (Exception ex)
            {
                resolverContext.Logger.LogMessage("KoreBuild SDK resolver encountered unexpected error: " + ex.ToString(), MessageImportance.High);
                return factory.IndicateFailure(null);
            }
        }

        private SdkResult ResolveImpl(SdkReference sdkReference, SdkResolverContext resolverContext, SdkResultFactory factory)
        {
            if (!_supportedSdks.Any(n => sdkReference.Name.Equals(n, StringComparison.OrdinalIgnoreCase)))
            {
                // let other resolvers run first
                return factory.IndicateFailure(null);
            }

            if (string.IsNullOrEmpty(KoreBuildHome))
            {
                return factory.IndicateFailure(new[] { "Could not identify the location of korebuild tools." });
            }

            string korebuildFolder;
            if (Environment.GetEnvironmentVariable("KoreBuildSdksPath") != null)
            {
                // env override
                korebuildFolder = Environment.GetEnvironmentVariable("KoreBuildSdksPath");
            }
            else
            {
                var lockFile = TryFindKoreBuildLockFile(resolverContext.ProjectFilePath);
                if (lockFile == null || !lockFile.Exists)
                {
                    return factory.IndicateFailure(new[] { $"Failed to find korebuild-lock.txt for project '{resolverContext.ProjectFilePath}'. This is required to resolve Sdk '{sdkReference.Name}' " });
                }

                var version = File.ReadAllLines(lockFile.FullName).Last(l => !string.IsNullOrWhiteSpace(l))?.Trim();

                korebuildFolder = Path.Combine(KoreBuildHome, version);

                resolverContext.Logger.LogMessage($"Using KoreBuild folder to resolve SDKs: {korebuildFolder}", MessageImportance.Low);
            }

            var sdkPath = Path.Combine(korebuildFolder, "msbuild", sdkReference.Name, "Sdk");

            return Directory.Exists(sdkPath)
                ? factory.IndicateSuccess(sdkPath, string.Empty)
                : factory.IndicateFailure(new[] { $"Could not find SDK named '{sdkReference.Name}' in {sdkPath}. Make sure the korebuild-lock.txt file is up to date." });
        }

        private static FileInfo TryFindKoreBuildLockFile(string project)
        {
            var dir = new DirectoryInfo(Path.GetDirectoryName(project));
            FileInfo lockFile = null;

            while (dir != null)
            {
                var lockFiles = dir.GetFiles("korebuild-lock.txt");
                if (lockFiles?.Length > 0)
                {
                    lockFile = lockFiles[0];
                    break;
                }
                dir = dir.Parent;
            }

            return lockFile;
        }

        private static string InitializeKoreBuildHome()
        {
            var dotnetHome = Environment.GetEnvironmentVariable("DOTNET_HOME") ?? Environment.GetEnvironmentVariable("DOTNET_INSTALL_DIR");

            if (string.IsNullOrEmpty(dotnetHome))
            {
                var home = Environment.GetEnvironmentVariable("USERPROFILE") ?? Environment.GetEnvironmentVariable("HOME");
                dotnetHome = Path.Combine(home, ".dotnet");
            }
#if NET46
            dotnetHome = Path.Combine(dotnetHome, "x64");
#elif NETSTANDARD2_0
            if (RuntimeInformation.IsOSPlatform(OSPlatform.Windows))
            {
                dotnetHome = Path.Combine(dotnetHome, "x64");
            }
#else
#error Update target frameworks
#endif

            return Path.Combine(dotnetHome, "buildtools", "korebuild");
        }
    }
}
