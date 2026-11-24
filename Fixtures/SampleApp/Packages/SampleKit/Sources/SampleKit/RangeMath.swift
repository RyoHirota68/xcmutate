// D14: ローカル SPM パッケージの @inlinable な公開関数。本体はモジュールの外に埋め込まれるため、
// ファイル内の fileprivate なヘルパーを参照できない。ツールは対象外にする。
@inlinable public func isInRange(_ v: Int, _ lo: Int, _ hi: Int) -> Bool { v >= lo && v <= hi }  // @case D14-inlinable

// D14: 同じパッケージの普通の公開関数は対象にする。
public func isPositive(_ v: Int) -> Bool { v > 0 }  // @case D14-plain
