//
// Copyright © 2020 osy. All rights reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//

import SwiftUI

@available(iOS 14, macOS 11, *)
struct VMDetailsView: View {
    @ObservedObject var vm: UTMVirtualMachine
    @EnvironmentObject private var data: UTMData
    @Environment(\.presentationMode) private var presentationMode: Binding<PresentationMode>
    #if !os(macOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass: UserInterfaceSizeClass?
    
    private var regularScreenSizeClass: Bool {
        horizontalSizeClass == .regular
    }
    private let workaroundScrollbarBug: Bool = false
    #else
    private let regularScreenSizeClass: Bool = true
    private var workaroundScrollbarBug: Bool {
        NSScroller.preferredScrollerStyle == .legacy
    }
    #endif
    
    private var sizeLabel: String {
        let size = data.computeSize(for: vm)
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
    
    var body: some View {
        if vm.isDeleted {
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Text("This virtual machine has been removed.")
                        .font(.headline)
                    Spacer()
                }
                Spacer()
            }
        } else {
            ScrollView(.vertical, showsIndicators: !workaroundScrollbarBug) {
                Screenshot(vm: vm, large: regularScreenSizeClass)
                let notes = vm.detailsNotes ?? ""
                if regularScreenSizeClass && !notes.isEmpty {
                    HStack(alignment: .top) {
                        Details(vm: vm, sizeLabel: sizeLabel)
                            .frame(maxWidth: .infinity)
                        Text(notes)
                            .font(.body)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding([.leading, .trailing])
                    }.padding([.leading, .trailing])
                    #if os(macOS)
                    if let appleVM = vm as? UTMAppleVirtualMachine {
                        VMAppleRemovableDrivesView(vm: appleVM, config: appleVM.appleConfig)
                            .padding([.leading, .trailing, .bottom])
                    } else {
                        VMRemovableDrivesView(vm: vm as! UTMQemuVirtualMachine)
                            .padding([.leading, .trailing, .bottom])
                    }
                    #else
                    VMRemovableDrivesView(vm: vm as! UTMQemuVirtualMachine)
                        .padding([.leading, .trailing, .bottom])
                    #endif
                } else {
                    VStack {
                        Details(vm: vm, sizeLabel: sizeLabel)
                        if !notes.isEmpty {
                            Text(notes)
                                .font(.body)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        #if os(macOS)
                        if let appleVM = vm as? UTMAppleVirtualMachine {
                            VMAppleRemovableDrivesView(vm: appleVM, config: appleVM.appleConfig)
                        } else if let qemuVM = vm as? UTMQemuVirtualMachine {
                            VMRemovableDrivesView(vm: qemuVM)
                        }
                        #else
                        VMRemovableDrivesView(vm: vm as! UTMQemuVirtualMachine)
                        #endif
                    }.padding([.leading, .trailing, .bottom])
                }
            }.labelStyle(DetailsLabelStyle())
            .modifier(VMOptionalNavigationTitleModifier(vm: vm))
            .modifier(VMToolbarModifier(vm: vm, bottom: !regularScreenSizeClass))
            .sheet(isPresented: $data.showSettingsModal) {
                #if os(macOS)
                if let appleVM = vm as? UTMAppleVirtualMachine {
                    VMSettingsView(vm: appleVM, config: appleVM.appleConfig)
                        .environmentObject(data)
                } else if let qemuVM = vm as? UTMQemuVirtualMachine {
                    VMSettingsView(vm: qemuVM, config: qemuVM.qemuConfig)
                        .environmentObject(data)
                }
                #else
                VMSettingsView(vm: vm as! UTMQemuVirtualMachine, config: vm.config as! UTMQemuConfiguration)
                    .environmentObject(data)
                #endif
            }
        }
    }
}

/// Returns just the content under macOS but adds the title on iOS. #3099
@available(iOS 14, macOS 11, *)
private struct VMOptionalNavigationTitleModifier: ViewModifier {
    @ObservedObject var vm: UTMVirtualMachine
    
    func body(content: Content) -> some View {
        #if os(macOS)
        return content.navigationSubtitle(vm.detailsTitleLabel)
        #else
        return content.navigationTitle(vm.detailsTitleLabel)
        #endif
    }
}

@available(iOS 14, macOS 11, *)
struct Screenshot: View {
    @ObservedObject var vm: UTMVirtualMachine
    let large: Bool
    @EnvironmentObject private var data: UTMData
    
    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color.black)
            if vm.screenshot != nil {
                #if os(macOS)
                Image(nsImage: vm.screenshot!.image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                #else
                Image(uiImage: vm.screenshot!.image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                #endif
            }
            Rectangle()
                .fill(Color(red: 230/255, green: 229/255, blue: 235/255))
                .blendMode(.hardLight)
            if vm.isBusy {
                BigWhiteSpinner()
            } else if vm.state == .vmStopped {
                Button(action: { data.run(vm: vm) }, label: {
                    Label("Run", systemImage: "play.circle.fill")
                        .labelStyle(.iconOnly)
                        .font(Font.system(size: 96))
                        .foregroundColor(Color.black)
                }).buttonStyle(.plain)
            }
        }.aspectRatio(CGSize(width: 16, height: 9), contentMode: large ? .fill : .fit)
    }
}

@available(iOS 14, macOS 11, *)
struct Details: View {
    @ObservedObject var vm: UTMVirtualMachine
    let sizeLabel: String
    @EnvironmentObject private var data: UTMData
    
    var body: some View {
        VStack {
            if vm.isShortcut {
                HStack {
                    plainLabel("Path", systemImage: "folder")
                    Spacer()
                    Text(vm.path!.path)
                        .foregroundColor(.secondary)
                }
            }
            HStack {
                plainLabel("Status", systemImage: "info.circle")
                Spacer()
                Text(vm.stateLabel)
                    .foregroundColor(.secondary)
            }
            HStack {
                plainLabel("Architecture", systemImage: "cpu")
                Spacer()
                Text(vm.detailsSystemArchitectureLabel)
                    .foregroundColor(.secondary)
            }
            HStack {
                plainLabel("Machine", systemImage: "desktopcomputer")
                Spacer()
                Text(vm.detailsSystemTargetLabel)
                    .foregroundColor(.secondary)
            }
            HStack {
                plainLabel("Memory", systemImage: "memorychip")
                Spacer()
                Text(vm.detailsSystemMemoryLabel)
                    .foregroundColor(.secondary)
            }
            HStack {
                plainLabel("Size", systemImage: "internaldrive")
                Spacer()
                Text(sizeLabel)
                    .foregroundColor(.secondary)
            }
            #if os(macOS)
            if let appleVM = vm as? UTMAppleVirtualMachine {
                HStack {
                    plainLabel("Serial", systemImage: "phone.connection")
                    Spacer()
                    if #available(macOS 12, *) {
                        Text(appleVM.serialPort?.name ?? "Inactive")
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)
                    } else {
                        Text(appleVM.serialPort?.name ?? "Inactive")
                            .foregroundColor(.secondary)
                    }
                }
            }
            #endif
        }.lineLimit(1)
        .truncationMode(.tail)
    }
    
    private func plainLabel(_ text: String, systemImage: String) -> some View {
        return Label {
            Text(LocalizedStringKey(text))
        } icon: {
            Image(systemName: systemImage).foregroundColor(.primary)
        }
    }
}

@available(iOS 14, macOS 11, *)
struct DetailsLabelStyle: LabelStyle {
    var color: Color = .accentColor
    
    func makeBody(configuration: Configuration) -> some View {
        Label(
            title: { configuration.title.font(.headline) },
            icon: {
                ZStack(alignment: .center) {
                    Rectangle()
                        .frame(width: 32, height: 32)
                        .foregroundColor(.clear)
                    configuration.icon.foregroundColor(color)
                }
            })
    }
}

@available(iOS 14, macOS 11, *)
struct VMDetailsView_Previews: PreviewProvider {
    @State static private var config = UTMQemuConfiguration()
    
    static var previews: some View {
        VMDetailsView(vm: UTMVirtualMachine(configuration: config, withDestinationURL: URL(fileURLWithPath: "")))
        .onAppear {
            config.shareDirectoryEnabled = true
            config.newDrive("", path: "", type: .disk, interface: "ide")
            config.newDrive("", path: "", type: .disk, interface: "sata")
            config.newDrive("", path: "", type: .CD, interface: "ide")
        }
    }
}
