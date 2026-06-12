import Foundation
import Testing
import RadrootsKitTesting

@Test func deterministicLaunchConfigurationAddsStableLocaleArguments() {
    let config = RadrootsUITestLaunchConfiguration.deterministic(
        environment: ["RADROOTS_TEST": "true"],
        arguments: ["--radroots-test"]
    )

    #expect(config.environment["RADROOTS_TEST"] == "true")
    #expect(config.arguments == [
        "--radroots-test",
        "-AppleLanguages",
        "(en)",
        "-AppleLocale",
        "en_US_POSIX"
    ])
}

@Test func launchConfigurationMergesEnvironmentOverBaseValues() {
    let config = RadrootsUITestLaunchConfiguration(
        environment: ["A": "override", "B": "new"],
        arguments: []
    )

    #expect(config.mergedEnvironment(over: ["A": "old", "C": "keep"]) == [
        "A": "override",
        "B": "new",
        "C": "keep"
    ])
}
