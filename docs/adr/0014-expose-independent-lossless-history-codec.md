# Expose an independent lossless history codec

<a id="adr-0014"></a>

- After the history invocation capability in [ADR-0013](0013-retain-original-input-through-invocation.md), consumer recipes duplicated message serialization. The owner requested a public Fabric codec so applications can retain native messages without reproducing their representation.
- Applications retain storage and transaction ownership; the codec owns only the message representation. An independent versioned envelope avoids exposing execution records or forcing store migrations when applications save history.
- Serializing partial generated suffixes requires keeping restoration separate from input admission validation. Closed objects refuse unknown fields so newer replay metadata cannot be silently discarded. Any message representation change requires a history format version review independently of execution-record evolution.
