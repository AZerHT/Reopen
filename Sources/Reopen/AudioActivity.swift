import CoreAudio
import Darwin

/// Which apps are playing or recording sound: a soft-closed window would keep doing it out of sight.
enum AudioActivity {
    /// Browsers play sound from helper processes. The private `responsibility_get_pid_responsible_for_pid`
    /// maps such a helper to its app; without it, only the app's own process is checked.
    private static let responsiblePID: ((pid_t) -> pid_t)? = {
        guard let handle = dlopen(nil, RTLD_NOW), let symbol = dlsym(handle, "responsibility_get_pid_responsible_for_pid") else { return nil }
        typealias Function = @convention(c) (pid_t) -> pid_t
        let function = unsafeBitCast(symbol, to: Function.self)
        return { function($0) }
    }()

    /// Needs the Core Audio process objects of macOS 14.2; earlier systems always answer false.
    static func isActive(pid: pid_t) -> Bool {
        guard #available(macOS 14.2, *) else { return false }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return false }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &objects) == noErr else { return false }

        for object in objects {
            guard read(UInt32.self, kAudioProcessPropertyIsRunningOutput, of: object) == 1
                    || read(UInt32.self, kAudioProcessPropertyIsRunningInput, of: object) == 1,
                  let processPID = read(pid_t.self, kAudioProcessPropertyPID, of: object) else { continue }
            if processPID == pid || responsiblePID?(processPID) == pid {
                return true
            }
        }
        return false
    }

    private static func read<T>(_ type: T.Type, _ selector: AudioObjectPropertySelector, of object: AudioObjectID) -> T? where T: FixedWidthInteger {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value = T.zero
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : nil
    }
}
