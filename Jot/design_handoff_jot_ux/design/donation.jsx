// Donation prompt + usage stats — quiet, dismissible, non-pushy.
//
// Three surfaces:
//   • Home card in Recents (one-shot, after 2h cumulative + 7 days + not dismissed)
//   • Stats moment above the About card in Settings
//   • "Donations" row inside the About card (always present)

const DONATION_CORAL = "#FF6B57";
const DONATION_CORAL_DEEP = "#E0533F";

// ─────────────────────────────────────────────────────────────
// Home card — sits between the hero stat card and the list card
// ─────────────────────────────────────────────────────────────
const DonationHomeCard = () => (
  <div style={{ padding: "0 14px 14px" }}>
    <div style={{
      background: "rgba(255,255,255,0.62)",
      backdropFilter: "blur(28px) saturate(200%)",
      WebkitBackdropFilter: "blur(28px) saturate(200%)",
      border: "0.5px solid rgba(0,0,0,0.05)",
      borderRadius: 20,
      padding: "18px 18px 16px",
      boxShadow: "0 1px 0 rgba(255,255,255,0.7) inset, 0 14px 36px -28px rgba(15,17,28,0.30)"
    }}>
      <div style={{
        fontSize: 15.5, fontWeight: 600, color: "#15171C", letterSpacing: -0.25,
        lineHeight: 1.35
      }}>Jot is free, and stays free.</div>
      <div style={{
        marginTop: 8,
        fontSize: 13, lineHeight: 1.5, letterSpacing: -0.1,
        color: "rgba(60,60,67,0.70)", textWrap: "pretty"
      }}>No accounts, no ads, nothing leaves your phone. If it's been useful, the donations page lists charities you can support.</div>

      <div style={{
        marginTop: 14,
        display: "flex", alignItems: "center", justifyContent: "space-between", gap: 10
      }}>
        <div style={{
          display: "inline-flex", alignItems: "center", gap: 6,
          padding: "8px 14px", borderRadius: 999,
          background: `linear-gradient(180deg, ${DONATION_CORAL}, ${DONATION_CORAL_DEEP})`,
          color: "#fff", fontSize: 13.5, fontWeight: 600, letterSpacing: -0.1,
          boxShadow: `0 4px 12px -2px ${DONATION_CORAL}66`
        }}>
          See donations
          <svg width="10" height="10" viewBox="0 0 10 10" fill="none">
            <path d="M3 1h6v6M9 1L3 7" stroke="#fff" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round"/>
          </svg>
        </div>
        <div style={{
          padding: "8px 6px", color: "rgba(60,60,67,0.65)",
          fontSize: 13, fontWeight: 500, letterSpacing: -0.05
        }}>Not now</div>
      </div>
    </div>
  </div>
);

// ─────────────────────────────────────────────────────────────
// Stats moment — two quiet lines above the About card
// ─────────────────────────────────────────────────────────────
const DonationStats = () => (
  <div style={{
    padding: "8px 22px 12px"
  }}>
    <div style={{
      fontSize: 17, fontWeight: 500, color: "#15171C", letterSpacing: -0.3,
      fontFamily: '"New York", "Iowan Old Style", Georgia, serif'
    }}>12 dictations</div>
    <div style={{
      fontSize: 13, color: "rgba(60,60,67,0.65)", marginTop: 2, letterSpacing: -0.05
    }}>About 5h 22m saved over typing.</div>
  </div>
);

// ─────────────────────────────────────────────────────────────
// "Donations" settings row — sits in the About card
// (consumed by SettingsScreen via the showDonation prop)
// ─────────────────────────────────────────────────────────────
const donationIcon = (
  <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="#fff" strokeWidth="2" strokeLinejoin="round" strokeLinecap="round">
    <rect x="3" y="11" width="18" height="9" rx="1.5"/>
    <path d="M3 7h18v4H3z"/>
    <path d="M12 20V7"/>
    <path d="M8 7c0-3 4-3 4 0"/>
    <path d="M16 7c0-3-4-3-4 0"/>
  </svg>
);

window.DonationHomeCard = DonationHomeCard;
window.DonationStats = DonationStats;
window.donationIcon = donationIcon;
