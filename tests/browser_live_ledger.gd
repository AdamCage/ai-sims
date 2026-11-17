extends SceneTree
## Account for one real browser request against the same native test budget.
const Ledger=preload("res://scripts/release_ai/usage_ledger.gd")

func _initialize()->void:
	var args:=OS.get_cmdline_user_args()
	if args.size()!=4 or args[0]!="--allow-paid" or not RegEx.create_from_string("^browser-test-[0-9a-f-]{36}$").search(args[2]):
		quit(2)
		return
	var ledger=Ledger.new()
	ledger.configure(1000.0,"user://release_usage_ledger.json",4)
	var ok:=false
	if ledger.status().storage_error=="" and args[3].is_valid_float():
		var amount:=args[3].to_float()
		if args[1]=="reserve" and amount>0.0 and amount<=10.0:
			ok=bool(ledger.reserve(args[2],amount,"action").ok)
		elif args[1]=="settle":
			ok=ledger.settle(args[2],amount,{"cost_source":"browser_acceptance"})
	ledger.release_storage_lease()
	print("BROWSER TEST LEDGER ", "OK" if ok else "FAILED")
	quit(0 if ok else 1)
