//
//  HowJotWorksPage.swift
//  Jot
//
//  Help → "How Jot works" — pushed from the Getting Started row. Reuses the
//  setup wizard's W4 teaching block (`HowItWorksScene`): the animated
//  mini-phone scene + the four numbered steps + the honest footnote, all with a
//  self-looping driver and a Reduce-Motion static frame. No wizard coupling.
//
//  Pushed on the ambient NavigationStack (the home modal wraps Help in one;
//  Settings provides its own) — exactly like the existing Feedback link. No
//  internal stack.
//

import SwiftUI

struct HowJotWorksPage: View {
    var body: some View {
        ZStack {
            WizardWallpaper()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("How Jot works")
                            .font(.system(size: 32, weight: .bold, design: .default))
                            .foregroundStyle(Color.jotInk)
                            .accessibilityAddTraits(.isHeader)

                        Text("The whole loop, in 30 seconds")
                            .font(.system(size: 16, weight: .regular, design: .default))
                            .foregroundStyle(Color.jotMute)
                    }
                    .padding(.top, 4)

                    // The shared W4 bundle: scene + numbered steps + footnote.
                    HowItWorksScene(showFootnote: true)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 4)
                }
                .padding(.horizontal, JotDesign.Spacing.pageMargin)
                .padding(.top, 4)
                .padding(.bottom, 32)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack {
        HowJotWorksPage()
    }
}
