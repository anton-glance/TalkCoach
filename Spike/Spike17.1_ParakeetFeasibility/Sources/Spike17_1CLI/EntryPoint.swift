// @main async entry point — avoids DispatchSemaphore blocking MainActor,
// which deadlocks FluidAudio's progressHandler dispatch back to MainActor.
import Foundation

@main
struct Spike17_1CLI_Main {
    static func main() async {
        let exitCode = await CLIRunner.run(args: CommandLine.arguments)
        exit(exitCode)
    }
}
