﻿// Copyright (c) .NET Foundation. All rights reserved.
// Licensed under the Apache License, Version 2.0. See License.txt in the project root for license information.

using System.Collections.Generic;

namespace NuGetPackageVerifier.Rules
{
    public class NonAdxVerificationCompositeRule : IPackageVerifierRule
    {
        readonly IPackageVerifierRule[] _rules = {
            new AuthenticodeSigningRule(),
        };

        public IEnumerable<PackageVerifierIssue> Validate(PackageAnalysisContext context)
        {
            foreach (var rule in _rules)
            {
                foreach (var issue in rule.Validate(context))
                {
                    yield return issue;
                }
            }
        }
    }
}
