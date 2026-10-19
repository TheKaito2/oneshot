// Trains a Create ML object detector on data/yolo (annotation files from tools/createml_data.py), headless and resumable.
// Checkpoints go to the session folder; rerunning the same command after a crash or reboot carries on from the last one.
//
//   swiftc -O tools/train_createml.swift -o build/train_createml
//   build/train_createml <name> <annotation prefix> <iterations> [data dir, default data/yolo] [tl|darknet]
//   e.g. build/train_createml cm-12class createml 1500                          -> models/cm-12class.mlmodel
//        build/train_createml cm-tiles createml-tiles 1500 data/yolo-tiles      (tiles: tools/createml_tiles.py)
//        build/train_createml cm-darknet createml 3000 data/yolo darknet        (full network, 416 px input)
//   Grade a checkpoint while a long run goes on: build/train_createml --export <session dir> <out.mlmodel>
//
// Transfer learning on Apple's ObjectPrint features: ~49 min per 300 iterations on the 8 GB M1 (measured Oct 2026).
import Combine
import CoreML
import CreateML
import Foundation

let args = CommandLine.arguments
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
if args.count == 4, args[1] == "--export" {
    // The newest checkpoint of a session, written as a model.
    let session = try MLObjectDetector.restoreTrainingSession(sessionParameters:
        MLTrainingSessionParameters(sessionDirectory: URL(fileURLWithPath: args[2])))
    guard let checkpoint = session.checkpoints.last else { print("no checkpoint yet"); exit(1) }
    try MLObjectDetector(checkpoint: checkpoint).write(to: URL(fileURLWithPath: args[3]))
    print("exported iteration \(checkpoint.iteration)")
    exit(0)
}
guard (4...6).contains(args.count), let iterations = Int(args[3]) else {
    print("usage: train_createml <name> <annotation prefix> <iterations> [data dir] [tl|darknet]")
    exit(2)
}
let name = args[1], prefix = args[2]
let data = root.appending(path: args.count > 4 ? args[4] : "data/yolo")
let darknet = args.count > 5 && args[5] == "darknet"
let session = root.appending(path: "runs/createml/\(name)")
let output = root.appending(path: "models/\(name).mlmodel")

func source(_ split: String) -> MLObjectDetector.DataSource {
    .directoryWithImages(at: data.appending(path: "images/\(split)"),
                         annotationFile: data.appending(path: "\(prefix)-\(split).json"))
}

let annotation = MLObjectDetector.AnnotationType.boundingBox(units: .pixel, origin: .topLeft, anchor: .center)
let sessionParameters = MLTrainingSessionParameters(sessionDirectory: session, reportInterval: 10,
                                                    checkpointInterval: 100, iterations: iterations)
let job: MLJob<MLObjectDetector>
do {
    if (try? FileManager.default.contentsOfDirectory(atPath: session.path(percentEncoded: false)))?.isEmpty == false {
        print("resuming \(session.path(percentEncoded: false))")
        job = try MLObjectDetector.resume(MLObjectDetector.restoreTrainingSession(sessionParameters: sessionParameters))
    } else {
        let parameters = MLObjectDetector.ModelParameters(
            validation: .dataSource(source("val")), batchSize: nil, maxIterations: iterations,
            algorithm: darknet ? .darknetYolo : .transferLearning(.objectPrint(revision: 1)))
        job = try MLObjectDetector.train(trainingData: source("train"), annotationType: annotation,
                                         parameters: parameters, sessionParameters: sessionParameters)
    }
} catch {
    print("could not start: \(error)")
    exit(1)
}

let started = Date()
var bag = Set<AnyCancellable>()
let progress = job.progress.publisher(for: \.fractionCompleted)
    .throttle(for: .seconds(60), scheduler: RunLoop.main, latest: true)
    .sink { fraction in
        let minutes = Int(Date().timeIntervalSince(started) / 60)
        print(String(format: "%@ %.1f%% after %d min", name, fraction * 100, minutes))
        fflush(stdout)
    }
progress.store(in: &bag)
job.checkpoints.sink { checkpoint in
    print("checkpoint at iteration \(checkpoint.iteration)")
    fflush(stdout)
}.store(in: &bag)
job.result.sink { completion in
    if case .failure(let error) = completion {
        print("training failed: \(error)")
        exit(1)
    }
} receiveValue: { detector in
    do {
        let metadata = MLModelMetadata(author: "OneShot", shortDescription:
            "OneShot product detector (\(name)), Create ML \(darknet ? "full network (darknetYolo)" : "transfer learning"), \(iterations) iterations", version: "1.0")
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try detector.write(to: output, metadata: metadata)
        let validation = detector.validationMetrics
        print("validation mAP@50: \(validation.meanAveragePrecision.IoU50) | mAP@50-95: \(validation.meanAveragePrecision.variedIoU)")
        print("wrote \(output.path(percentEncoded: false)) in \(Int(Date().timeIntervalSince(started) / 60)) min")
        exit(0)
    } catch {
        print("could not save: \(error)")
        exit(1)
    }
}.store(in: &bag)

RunLoop.main.run()
