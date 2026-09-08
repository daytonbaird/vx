import Foundation

setvbuf(stdout, nil, _IOLBF, 0)

let argv = Array(CommandLine.arguments.dropFirst())

let options: Options
do {
    options = try Options.parse(argv)
} catch {
    FileHandle.standardError.write(Data("vx-e2e: \(String(describing: error))\n\n".utf8))
    print(Options.usage)
    exit(2)
}

switch options.command {
case .help:
    print(Options.usage)
    exit(0)

case .list:
    print(Registry.listing())
    exit(0)

case .preflight(let prompt):
    let report = Preflight.run(options: options, prompt: prompt)
    print(Preflight.render(report))
    exit(report.passed ? 0 : 1)

case .run(let names):
    let types: [Scenario.Type]
    do {
        types = try Registry.resolve(names)
    } catch {
        FileHandle.standardError.write(Data("vx-e2e: \(String(describing: error))\n".utf8))
        exit(2)
    }
    do {
        let ok = try Runner(options: options).run(types)
        exit(ok ? 0 : 1)
    } catch {
        FileHandle.standardError.write(Data("vx-e2e: \(String(describing: error))\n".utf8))
        exit(1)
    }
}
