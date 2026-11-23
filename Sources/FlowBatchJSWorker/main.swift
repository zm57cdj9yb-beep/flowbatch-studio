import Foundation
import JavaScriptCore

private struct JSWorkerRequest: Decodable {
    let code: String
    let asset: AssetInput
}

private struct AssetInput: Decodable {
    let fileName: String
    let fileExtension: String
    let width: Double
    let height: Double
    let dpi: Int
    let metadata: [String: String]
    let tags: [String]
}

private struct JSWorkerResponse: Encodable {
    var skip: Bool = false
    var outputNameOverride: String?
    var metadata: [String: String] = [:]
    var logs: [String] = []
    var error: String?
}

private func runSandboxed() {
    let inputData = FileHandle.standardInput.readDataToEndOfFile()
    var response = JSWorkerResponse()

    do {
        let req = try JSONDecoder().decode(JSWorkerRequest.self, from: inputData)
        guard let vm = JSVirtualMachine(), let ctx = JSContext(virtualMachine: vm) else {
            response.error = "Unable to initialize JSVirtualMachine"
            emit(response)
            return
        }

        var logs: [String] = []
        var skipFlag = false
        var outputNameOverride: String?
        var metadata = req.asset.metadata

        ctx.exceptionHandler = { _, exception in
            if let message = exception?.toString() {
                response.error = message
            }
        }

        // Minimal console.log binding only
        let logFn: @convention(block) (JSValue) -> Void = { val in
            logs.append(val.toString() ?? "")
        }
        let consoleObj = JSValue(newObjectIn: ctx)
        consoleObj?.setObject(logFn, forKeyedSubscript: "log" as NSString)
        ctx.setObject(consoleObj, forKeyedSubscript: "console" as NSString)

        // Plain frozen-capability asset DTO (zero Cocoa/FileManager/Process access)
        let assetObj = JSValue(newObjectIn: ctx)
        assetObj?.setObject(req.asset.fileName, forKeyedSubscript: "fileName" as NSString)
        assetObj?.setObject(req.asset.fileExtension, forKeyedSubscript: "fileExtension" as NSString)
        assetObj?.setObject(req.asset.width, forKeyedSubscript: "width" as NSString)
        assetObj?.setObject(req.asset.height, forKeyedSubscript: "height" as NSString)
        assetObj?.setObject(req.asset.dpi, forKeyedSubscript: "dpi" as NSString)
        assetObj?.setObject(req.asset.tags, forKeyedSubscript: "tags" as NSString)
        assetObj?.setObject(req.asset.metadata, forKeyedSubscript: "metadata" as NSString)

        let skipFn: @convention(block) () -> Void = {
            skipFlag = true
        }
        let setOutputNameFn: @convention(block) (String) -> Void = { name in
            outputNameOverride = name
        }
        let setMetadataFn: @convention(block) (String, String) -> Void = { key, value in
            metadata[key] = value
        }

        assetObj?.setObject(skipFn, forKeyedSubscript: "skip" as NSString)
        assetObj?.setObject(setOutputNameFn, forKeyedSubscript: "setOutputName" as NSString)
        assetObj?.setObject(setMetadataFn, forKeyedSubscript: "setMetadata" as NSString)
        ctx.setObject(assetObj, forKeyedSubscript: "asset" as NSString)

        // Execute user code, then invoke processAsset(asset) if defined
        ctx.evaluateScript(req.code)
        if response.error == nil,
           let fn = ctx.objectForKeyedSubscript("processAsset"),
           !fn.isUndefined, fn.isObject {
            _ = fn.call(withArguments: [assetObj as Any])
        }

        response.skip = skipFlag
        response.outputNameOverride = outputNameOverride
        response.metadata = metadata
        response.logs = logs
    } catch {
        response.error = error.localizedDescription
    }

    emit(response)
}

private func emit(_ response: JSWorkerResponse) {
    if let data = try? JSONEncoder().encode(response) {
        FileHandle.standardOutput.write(data)
    }
}

runSandboxed()
