describe("AI conversation session", function()
	it("parses and strips one answer turn", function()
		local conversation = LoadModule("Modules/AIConversation")
		local displayText, turn, err = conversation:ParseTurn(
			"Your defenses need more life.\n<turn>"
				.. '{"next":"answer","goal":"defense review","reason":"enough PoB evidence"}'
				.. "</turn>"
		)

		assert.is_nil(err)
		assert.are.equal("Your defenses need more life.", displayText)
		assert.are.equal("answer", turn.next)
		assert.are.equal("defense review", turn.goal)
	end)

	it("accepts semantically equivalent turn fixtures without local intent matching", function()
		local conversation = LoadModule("Modules/AIConversation")
		local fixtures = {
			"Could you make this sturdier?",
			"Quero sobreviver melhor em mapas.",
		}
		for _, prose in ipairs(fixtures) do
			local _, turn, err = conversation:ParseTurn(
				prose .. '\n<turn>{"next":"clarify","goal":"choose defense priority",'
					.. '"reason":"a material preference is missing",'
					.. '"question":{"id":"priority","prompt":"Damage or defense?"}}</turn>'
			)
			assert.is_nil(err)
			assert.are.equal("clarify", turn.next)
			assert.are.equal("priority", turn.question.id)
		end
	end)

	it("requires one well-formed turn block", function()
		local conversation = LoadModule("Modules/AIConversation")
		local _, missingTurn, missingError = conversation:ParseTurn("Plain response")
		assert.is_nil(missingTurn)
		assert.is_truthy(missingError:find("missing", 1, true))

		local _, malformedTurn, malformedError = conversation:ParseTurn(
			'<turn>{"next":"clarify","goal":"build","reason":"need a choice"}</turn>'
		)
		assert.is_nil(malformedTurn)
		assert.is_truthy(malformedError:find("question", 1, true))

		local _, multipleTurn, multipleError = conversation:ParseTurn(
			'<turn>{"next":"answer","goal":"a","reason":"b"}</turn>'
				.. '<turn>{"next":"answer","goal":"a","reason":"b"}</turn>'
		)
		assert.is_nil(multipleTurn)
		assert.is_truthy(multipleError:find("multiple", 1, true))
	end)

	it("preserves one clarification answer in its session", function()
		local conversation = LoadModule("Modules/AIConversation")
		local session = assert(conversation:BeginRequest(conversation:NewSession(), "fingerprint"))
		local _, turn, err = conversation:ParseTurn(
			'<turn>{"next":"clarify","goal":"choose priority","reason":"damage and defense trade off",'
				.. '"question":{"id":"priority","prompt":"What should I prioritize?",'
				.. '"options":["damage","defense","balanced"]}}</turn>'
		)
		assert.is_nil(err)
		assert.is_true(conversation:ApplyTurn(session, turn, "fingerprint"))
		assert.are.equal("awaiting_user", session.state)
		assert.are.equal("priority", session.pendingQuestion.id)

		assert.is_true(conversation:SubmitAnswer(session, "defense"))
		assert.are.equal("understanding", session.state)
		assert.are.equal("defense", session.constraints.priority)
		assert.is_nil(session.pendingQuestion)
		conversation:RecordContextExpansion(session, { "gems" })
		local resumed = assert(conversation:BeginRequest(session, "fingerprint"))
		assert.are.equal("defense", resumed.constraints.priority)
		assert.same({}, resumed.loadedContexts)
		assert.are.equal(0, resumed.contextAttempts)
	end)

	it("normalizes numeric clarification options into strings", function()
		local conversation = LoadModule("Modules/AIConversation")
		local _, turn, err = conversation:ParseTurn(
			'<turn>{"next":"clarify","goal":"choose target level","reason":"level materially changes the plan",'
				.. '"question":{"id":"targetLevel","prompt":"Which target level?",'
				.. '"options":[30,60,100]}}</turn>'
		)
		assert.is_nil(err)
		assert.same({ "30", "60", "100" }, turn.question.options)
	end)

	it("rejects a changed build while a clarification is pending", function()
		local conversation = LoadModule("Modules/AIConversation")
		local session = assert(conversation:BeginRequest(conversation:NewSession(), "first"))
		local _, turn = conversation:ParseTurn(
			'<turn>{"next":"clarify","goal":"choose priority","reason":"trade off",'
				.. '"question":{"id":"priority","prompt":"Choose one"}}</turn>'
		)
		assert.is_true(conversation:ApplyTurn(session, turn, "first"))
		local pendingSession, pendingError = conversation:BeginRequest(session, "first")
		assert.is_nil(pendingSession)
		assert.is_truthy(pendingError:find("requires", 1, true))
		assert.is_true(conversation:SubmitAnswer(session, "defense"))

		local resetSession, resetError = conversation:BeginRequest(session, "second")
		assert.is_nil(resetSession)
		assert.is_truthy(resetError:find("changed", 1, true))
	end)
end)
