import Foundation
import Darwin

@main
struct Spike17_3CLI_Main {
    static func main() async {
        let code = await CLIRunner.run(args: CommandLine.arguments)
        Darwin.exit(code)
    }
}
