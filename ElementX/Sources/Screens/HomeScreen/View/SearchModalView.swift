//
// Copyright 2024 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
// Please see LICENSE in the repository root for full details.

import Combine

//

import Compound
import SwiftUI

struct SearchModalView: View {
    @Environment(\.dismiss) private var dismiss
    
    @ObservedObject var context: HomeScreenViewModel.Context
    @State private var searchQuery = ""
    @State private var isSearching = false
    @State private var searchResult: [String: Any]?
    @State private var errorMessage: String?
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                TextField("Search", text: $searchQuery)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .padding(.horizontal)
                
                Button {
                    performSearch()
                } label: {
                    Text("Search")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.compound(.primary))
                .padding(.horizontal)
                .disabled(searchQuery.isEmpty || isSearching)
                
                if isSearching {
                    ProgressView()
                        .padding()
                } else if let errorMessage {
                    Text(errorMessage)
                        .foregroundColor(.red)
                        .padding()
                } else if let searchResult {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Search Results")
                                .font(.headline)
                                .padding(.horizontal)
                            
                            if let answer = searchResult["status"] as? String, answer == "success" {
                                if let answerText = searchResult["answer"] as? String {
                                    Text(answerText)
                                        .padding()
                                        .background(Color.compound.bgSubtleSecondary)
                                        .cornerRadius(8)
                                        .padding(.horizontal)
                                }
                                
                                if let contexts = searchResult["contexts"] as? [[String: Any]] {
                                    let eventCount = contexts.reduce(0) { count, context in
                                        if let eventIds = context["event_ids"] as? [String] {
                                            return count + eventIds.count
                                        }
                                        return count
                                    }
                                    
                                    Text("Found in \(eventCount) messages across \(contexts.count) rooms")
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                        .padding(.horizontal)
                                }
                            } else {
                                Text("No results found")
                                    .padding()
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                
                Spacer()
            }
            .padding(.top)
            .navigationTitle("Search Messages")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Text("Cancel")
                    }
                }
            }
        }
    }
    
    private func performSearch() {
        guard !searchQuery.isEmpty else { return }
        
        isSearching = true
        errorMessage = nil
        
        context.send(viewAction: .searchMessages(query: searchQuery) { result in
            DispatchQueue.main.async {
                isSearching = false
                
                switch result {
                case .success(let response):
                    searchResult = response
                case .failure(let error):
                    errorMessage = "Search failed: \(error.localizedDescription)"
                }
            }
        })
    }
}

struct SearchModalView_Previews: PreviewProvider, TestablePreview {
    static var previews: some View {
        let clientProxy = ClientProxyMock(.init())
        let userSession = UserSessionMock(.init(clientProxy: clientProxy))
        let viewModel = HomeScreenViewModel(userSession: userSession,
                                            analyticsService: ServiceLocator.shared.analytics,
                                            appSettings: ServiceLocator.shared.settings,
                                            selectedRoomPublisher: CurrentValueSubject<String?, Never>(nil).asCurrentValuePublisher(),
                                            userIndicatorController: ServiceLocator.shared.userIndicatorController)
        return SearchModalView(context: viewModel.context)
    }
}
