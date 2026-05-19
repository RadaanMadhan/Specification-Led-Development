// Alloy Model for Data Anonymization Pipeline

sig User {}

sig PIIField {}

abstract sig Record {
    pii: set PIIField,
    quasi_identifier: Int
}

sig RawRecord extends Record {
    owner: User
}

sig AnonymizedRecord extends Record {
    equivalent_class: one EquivalenceClass
}

sig EquivalenceClass {
    records: set AnonymizedRecord
}

// Ensure no PII in anonymized records
fact {
    no r: AnonymizedRecord | some r.pii
}

// Define k-anonymity constraint
// Every anonymized record must belong to an equivalence class of size >= k
pred k_anonymity[k: Int] {
    all ec: EquivalenceClass | #ec.records >= k
}

// Example constraint for k=5
fact {
    k_anonymity[5]
}

// Dummy scope for analysis
run {} for 5 but 5 int
