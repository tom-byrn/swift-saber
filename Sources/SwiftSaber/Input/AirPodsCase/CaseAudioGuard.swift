// Keeps sound and the microphone off the AirPods during a closed-case session, and keeps their
// audio link awake with silence. Ported from AirPointer (github.com/musubipapi/airpointer,
// Session/AudioOutputGuard.swift, MIT License, Copyright (c) 2026 Andy Gao) with names changed.
import Foundation
import CoreAudio

enum ProtectedAudioRole:String,CaseIterable{
    case playback,systemSounds,input
    var selector:AudioObjectPropertySelector{
        switch self{
        case .playback:return kAudioHardwarePropertyDefaultOutputDevice
        case .systemSounds:return kAudioHardwarePropertyDefaultSystemOutputDevice
        case .input:return kAudioHardwarePropertyDefaultInputDevice
        }
    }
}

struct PointerAudioDevice:Equatable{
    let id:AudioDeviceID,uid:String,name:String,transport:UInt32
    var alive=true,playback=true,systemSounds=true,input=false
    var builtIn:Bool{transport==kAudioDeviceTransportTypeBuiltIn}
    func supports(_ role:ProtectedAudioRole)->Bool{
        guard alive else{return false}
        switch role{
        case .playback:return playback
        case .systemSounds:return systemSounds
        case .input:return input
        }
    }
}

struct PointerAudioOutputPolicy{
    var targetAddress:String?
    private var preferred:[ProtectedAudioRole:String]=[:]
    private var moved:[ProtectedAudioRole:(from:String,to:String)]=[:]
    init(targetAddress:String?){self.targetAddress=targetAddress}
    // Each moved role as [from,to], in a form that can be saved.
    var moves:[String:[String]]{
        get{Dictionary(uniqueKeysWithValues:moved.map{($0.key.rawValue,[$0.value.from,$0.value.to])})}
        set{moved=[:];for (name,move) in newValue{if let role=ProtectedAudioRole(rawValue:name),move.count==2{moved[role]=(move[0],move[1])}}}
    }
    private func compact(_ value:String)->String{value.lowercased().filter{$0.isLetter || $0.isNumber}}
    func isAirPods(_ output:PointerAudioDevice)->Bool{
        guard output.transport==kAudioDeviceTransportTypeBluetooth || output.transport==kAudioDeviceTransportTypeBluetoothLE else{return false}
        if let targetAddress,compact(targetAddress).count==12,compact(output.uid).contains(compact(targetAddress)){return true}
        return output.name.localizedCaseInsensitiveContains("airpods")
    }
    mutating func replacement(for role:ProtectedAudioRole,current:PointerAudioDevice?,devices:[PointerAudioDevice])->PointerAudioDevice?{
        guard let current else{return nil}
        if !isAirPods(current){
            if current.supports(role){preferred[role]=current.uid}
            return nil
        }
        let safe=devices.filter{$0.supports(role) && !isAirPods($0)}
        let replacement=safe.first{$0.uid==preferred[role]} ??
            safe.first{$0.builtIn && $0.uid=="BuiltInSpeakerDevice"} ??
            safe.first{$0.builtIn} ?? safe.first
        if let replacement{moved[role]=(moved[role]?.from ?? current.uid,replacement.uid)}
        return replacement
    }
    // Where a role goes back to once the session ends: nowhere if it was never moved, or if someone has chosen another device since.
    mutating func restoration(for role:ProtectedAudioRole,current:PointerAudioDevice?,devices:[PointerAudioDevice])->PointerAudioDevice?{
        guard let move=moved.removeValue(forKey:role),current?.uid==move.to else{return nil}
        return devices.first{$0.uid==move.from && $0.supports(role)}
    }
}

private enum PointerAudioHardware{
    static let system=AudioObjectID(kAudioObjectSystemObject)
    static func address(_ selector:AudioObjectPropertySelector,_ scope:AudioObjectPropertyScope=kAudioObjectPropertyScopeGlobal)->AudioObjectPropertyAddress{
        .init(mSelector:selector,mScope:scope,mElement:kAudioObjectPropertyElementMain)
    }
    static func number(_ object:AudioObjectID,_ selector:AudioObjectPropertySelector,_ scope:AudioObjectPropertyScope=kAudioObjectPropertyScopeGlobal)->UInt32?{
        var key=address(selector,scope),value:UInt32=0,size:UInt32=4
        return AudioObjectGetPropertyData(object,&key,0,nil,&size,&value)==noErr ? value:nil
    }
    static func string(_ object:AudioObjectID,_ selector:AudioObjectPropertySelector)->String?{
        var key=address(selector),value:Unmanaged<CFString>?,size=UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object,&key,0,nil,&size,&value)==noErr else{return nil}
        // Core Audio's CFString properties return an object owned by the caller.
        return value?.takeRetainedValue() as String?
    }
    static func outputs()->[PointerAudioDevice]{devices(kAudioObjectPropertyScopeOutput)}
    static func devices(for role:ProtectedAudioRole)->[PointerAudioDevice]{devices(role == .input ? kAudioObjectPropertyScopeInput:kAudioObjectPropertyScopeOutput)}
    private static func devices(_ scope:AudioObjectPropertyScope)->[PointerAudioDevice]{
        var key=address(kAudioHardwarePropertyDevices),size:UInt32=0
        guard AudioObjectGetPropertyDataSize(system,&key,0,nil,&size)==noErr,size>0 else{return []}
        var ids=[AudioDeviceID](repeating:0,count:Int(size)/MemoryLayout<AudioDeviceID>.size)
        guard ids.withUnsafeMutableBytes({AudioObjectGetPropertyData(system,&key,0,nil,&size,$0.baseAddress!)})==noErr else{return []}
        return ids.compactMap{id in
            var streams=address(kAudioDevicePropertyStreams,scope),bytes:UInt32=0
            guard AudioObjectGetPropertyDataSize(id,&streams,0,nil,&bytes)==noErr,bytes>0,
                  let uid=string(id,kAudioDevicePropertyDeviceUID),let name=string(id,kAudioObjectPropertyName),
                  let transport=number(id,kAudioDevicePropertyTransportType) else{return nil}
            let canBeDefault=number(id,kAudioDevicePropertyDeviceCanBeDefaultDevice,scope)==1,output=scope==kAudioObjectPropertyScopeOutput
            return PointerAudioDevice(id:id,uid:uid,name:name,transport:transport,
                alive:number(id,kAudioDevicePropertyDeviceIsAlive)==1,
                playback:output && canBeDefault,
                systemSounds:output && number(id,kAudioDevicePropertyDeviceCanBeDefaultSystemDevice,scope)==1,
                input:!output && canBeDefault)
        }
    }
    static func current(_ role:ProtectedAudioRole)->AudioDeviceID?{number(system,role.selector)}
    static func select(_ output:PointerAudioDevice,for role:ProtectedAudioRole)->OSStatus{
        var key=address(role.selector),id=output.id
        return AudioObjectSetPropertyData(system,&key,0,nil,UInt32(MemoryLayout<AudioDeviceID>.size),&id)
    }
}

// Keeps this paired device's output link active with zeros. System defaults are
// never selected here, and no input stream is opened. The closed-case pilot owns
// the lifetime; Core Audio work stays off the pointer's main run loop.
final class PointerSilentOutput{
    private let queue=DispatchQueue(label:"SwiftSaber.case-silent-output",qos:.userInitiated)
    private let target:String
    private var device:AudioDeviceID?,proc:AudioDeviceIOProcID?
    private var stopped=false,nextAttempt=0.0,lastError:OSStatus=0
    init(targetAddress:String){
        target=targetAddress.lowercased().filter{$0.isLetter || $0.isNumber}
    }
    deinit{releaseStream()}
    func refresh(){queue.async{[self] in
        guard !stopped else{return}
        if let device,PointerAudioHardware.number(device,kAudioDevicePropertyDeviceIsAlive)==1,
           PointerAudioHardware.number(device,kAudioDevicePropertyDeviceIsRunningSomewhere)==1{return}
        releaseStream()
        let now=ProcessInfo.processInfo.systemUptime
        guard now>=nextAttempt else{return};nextAttempt=now+2
        guard target.count==12,let output=PointerAudioHardware.outputs().first(where:{
            $0.alive && ($0.transport==kAudioDeviceTransportTypeBluetooth || $0.transport==kAudioDeviceTransportTypeBluetoothLE) &&
            $0.uid.lowercased().filter{$0.isLetter || $0.isNumber}.contains(target)
        }) else{return}
        var created:AudioDeviceIOProcID?
        lastError=AudioDeviceCreateIOProcID(output.id,{_,_,_,_,buffers,_,_ in
            for buffer in UnsafeMutableAudioBufferListPointer(buffers){
                if let data=buffer.mData{memset(data,0,Int(buffer.mDataByteSize))}
            }
            return noErr
        },nil,&created)
        if lastError==noErr,let created{
            device=output.id;proc=created
            lastError=AudioDeviceStart(output.id,created)
            if lastError != noErr{releaseStream()}
        }
    }}
    func stop(){queue.async{[self] in stopped=true;releaseStream()}}
    private func releaseStream(){
        if let device,let proc{_ = AudioDeviceStop(device,proc);_ = AudioDeviceDestroyIOProcID(device,proc)}
        proc=nil;device=nil
    }
}

// Keeps the default playback, alert and input devices off the AirPods. An app recording from the default input
// would otherwise put them in a hands-free call, and motion stops about 2 s later. No audio stream or Bluetooth reconnect.
// Only a session holds it, from Connect until it ends, and then whatever it moved goes back.
// The moves outlive the app, so they're saved, and a force quit or crash is put right at the next launch.
final class CaseAudioGuard{
    static let shared=CaseAudioGuard()
    private static let movesKey="SwiftSaber.caseAudioMovesToRestore"
    // Long enough that a session restarting after a drop doesn't move sound back and forth.
    private static let releaseAfter=2.0
    private var inSession=false,sessionChanges=0
    var protects=true{didSet{syncSession()}}
    func sessionStarted(target:String?){
        inSession=true;sessionChanges+=1
        queue.async{[self] in
            if let target{policy.targetAddress=target}
            enforce()
        }
        syncSession()
    }
    func sessionEnded(){
        inSession=false;sessionChanges+=1
        let change=sessionChanges
        DispatchQueue.main.asyncAfter(deadline:.now()+Self.releaseAfter){[weak self] in
            guard let self,self.sessionChanges==change else{return}
            self.syncSession()
        }
    }
    private func syncSession(){
        if inSession && protects{start()}else{queue.async{[self] in release()}}
    }
    private let queue=DispatchQueue(label:"SwiftSaber.case-audio-guard",qos:.userInitiated)
    private var policy:PointerAudioOutputPolicy
    private var listener:AudioObjectPropertyListenerBlock?
    private var installed:[AudioObjectPropertySelector]=[]
    init(targetAddress:String?=nil){policy=PointerAudioOutputPolicy(targetAddress:targetAddress)}
    func start(){queue.async{[weak self] in
        guard let self,self.listener==nil else{return}
        let listener:AudioObjectPropertyListenerBlock={ [weak self] _,_ in self?.enforce() }
        self.listener=listener
        for selector in ProtectedAudioRole.allCases.map(\.selector)+[kAudioHardwarePropertyDevices]{
            var key=PointerAudioHardware.address(selector)
            let status=AudioObjectAddPropertyListenerBlock(PointerAudioHardware.system,&key,self.queue,listener)
            if status==noErr{self.installed.append(selector)}
        }
        self.enforce()
    }}
    func stop(){queue.sync{release()}}
    func restoreAfterCrash(){queue.async{[self] in
        guard listener==nil,let saved=UserDefaults.standard.dictionary(forKey:Self.movesKey) as? [String:[String]] else{return}
        policy.moves=saved;restoreMoves()
    }}
    private func release(){
        guard listener != nil else{return}
        if let listener{
            for selector in installed{var key=PointerAudioHardware.address(selector);_ = AudioObjectRemovePropertyListenerBlock(PointerAudioHardware.system,&key,queue,listener)}
        }
        installed=[];listener=nil
        restoreMoves()
    }
    private func restoreMoves(){
        for role in ProtectedAudioRole.allCases{
            let devices=PointerAudioHardware.devices(for:role)
            let id=PointerAudioHardware.current(role),current=devices.first{$0.id==id}
            if let back=policy.restoration(for:role,current:current,devices:devices){_ = PointerAudioHardware.select(back,for:role)}
        }
        UserDefaults.standard.removeObject(forKey:Self.movesKey)
    }
    private func enforce(){
        guard listener != nil else{return}
        for role in ProtectedAudioRole.allCases{
            let devices=PointerAudioHardware.devices(for:role)
            let id=PointerAudioHardware.current(role),current=devices.first{$0.id==id}
            guard let replacement=policy.replacement(for:role,current:current,devices:devices) else{continue}
            UserDefaults.standard.set(policy.moves,forKey:Self.movesKey)
            _=PointerAudioHardware.select(replacement,for:role)
        }
    }
}
