@{
    # CI fails on Error severity only; warnings are reported for review.
    Severity     = @('Error', 'Warning')

    ExcludeRules = @(
        # The launcher, stop script and doctor are interactive console tools;
        # coloured Write-Host output is their user interface.
        'PSAvoidUsingWriteHost'
    )
}
