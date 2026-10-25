import Foundation
import Testing

@testable import Loops

private func runner(_ n: Int, loaded: Bool = false, atLogin: Bool = true, busy: Bool = false) -> Runner {
  Runner(
    id: n, name: "mac-runner-\(n)", online: loaded, busy: busy, service: "actions.runner.acme-shop.mac-runner-\(n)", loaded: loaded,
    atLogin: atLogin)
}

@MainActor
struct RunnerPermission {
  @Test func startingARunnerAsksFirstAndRunsNothing() {
    let ci = CI()
    ci.ask(.start, [runner(1), runner(2)])
    #expect(ci.request?.op == .start)
    #expect(ci.request?.runners.map(\.id) == [1, 2])
    #expect(ci.acting.isEmpty)
  }

  @Test func stoppingARunnerAsksFirstAndRunsNothing() {
    let ci = CI()
    ci.ask(.stop, [runner(1, loaded: true)])
    #expect(ci.request?.op == .stop)
    #expect(ci.acting.isEmpty)
  }

  @Test func aRunnerAlreadyOffAtLoginHasNothingToStop() {
    let ci = CI()
    ci.ask(.stop, [runner(1, atLogin: false)])
    #expect(ci.request == nil)
  }

  @Test func aRunnerWithoutALaunchAgentCannotBeStarted() {
    let ci = CI()
    ci.ask(.start, [Runner(id: 1, name: "elsewhere", online: false, busy: false)])
    #expect(ci.request == nil)
  }

  @Test func stoppingABusyRunnerSaysItsJobFails() {
    let request = RunnerRequest(op: .stop, runners: [runner(1, loaded: true, busy: true)])
    #expect(request.message.contains("fails"))
    #expect(request.title == "Stop Runner 1?")
  }

  @Test func launchdDisabledServicesAreRead() {
    let out = """
      disabled services = {
      \t"actions.runner.acme-shop.mac-runner-1" => disabled
      \t"com.apple.example" => enabled
      \t"actions.runner.acme-shop.mac-runner-2" => true
      }
      """
    #expect(CI.disabled(out) == ["actions.runner.acme-shop.mac-runner-1", "actions.runner.acme-shop.mac-runner-2"])
  }
}
