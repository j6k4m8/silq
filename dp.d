import std.conv: text;
import std.string: split;
import std.algorithm: map;
import std.array: array;
import std.range: iota;
import std.string: startsWith;
import std.typecons: q=tuple,Q=Tuple;

import backend,options;
import distrib,error;
import dexpr,hashtable,util;
import expression,declaration,type;
import semantic_,scope_,context;

import std.random; // (for InferenceMethod.simulate)

class Bruteforce: Backend{
	this(string sourceFile){
		this.sourceFile=sourceFile;
	}
	override Distribution analyze(FunctionDef def,ErrorHandler err){
		DExpr[string] fields;
		foreach(i,a;def.params) fields[a.getName]=dVar(a.getName);
		DExpr init=dRecord(fields);
		auto interpreter=Interpreter(def,def.body_,init,false);
		auto ret=distInit();
		interpreter.runFun(ret);
		return ret.toDistribution();
	}
private:
	string sourceFile;
}

auto distInit(){
	return Dist(MapX!(DExpr,DExpr).init,zero,SetX!string.init);
}
struct Dist{
	MapX!(DExpr,DExpr) state;
	DExpr error;
	SetX!string tmpVars;
	// @disable this();
	this(MapX!(DExpr,DExpr) state,DExpr error,SetX!string tmpVars){
		this.state=state;
		this.error=error;
		this.tmpVars=tmpVars;
	}
	Dist dup(){ return Dist(state.dup,error,tmpVars.dup); static assert(this.tupleof.length==3); }
	void addTmpVar(string var){ tmpVars.insert(var); }
	Dist marginalizeTemporaries(){
		if(!tmpVars.length) return this;
		auto r=distInit;
		r.error=error;
		foreach(k,v;state){
			auto rec=cast(DRecord)k;
			assert(!!rec,text(k));
			auto val=rec.values.dup;
			foreach(x;tmpVars) val.remove(x);
			r.add(dRecord(val),v);
		}
		tmpVars.clear();
		return r;
	}
	void add(DExpr k,DExpr v){
		if(k in state) state[k]=(state[k]+v).simplify(one);
		else state[k]=v;
		if(state[k] == zero) state.remove(k);
	}
	void opOpAssign(string op:"+")(Dist r){
		foreach(k,v;r.state)
			add(k,v);
		error=(error+r.error).simplify(one);
		foreach(t;r.tmpVars) addTmpVar(t);
	}
	Dist map(DLambda lambda){
		if(opt.trace) writeln("particle-size: ",state.length);
		auto r=distInit;
		r.copyNonState(this);
		foreach(k,v;state) r.add(dApply(lambda,k).simplify(one),v);
		return r;
	}
	DExpr expectation(DLambda lambda,bool hasFrame){
		if(!hasFrame){
			DExpr r1=zero,r2=zero;
			foreach(k,v;state){
				r1=(r1+v*dApply(lambda,k)).simplify(one);
				r2=(r2+v).simplify(one);
			}
			return (r1/r2).simplify(one);
		}
		MapX!(DExpr,Q!(Q!(DExpr,DExpr)[],DExpr,DExpr)) byFrame;
		foreach(k,v;state){
			auto frame=dField(k,"`frame").simplify(one);
			if(frame in byFrame) byFrame[frame][0]~=q(k,v);
			else byFrame[frame]=q([q(k,v)],zero,zero);
		}
		foreach(k,ref v;byFrame){
			foreach(x;v[0]){
				v[1]=(v[1]+x[1]*dApply(lambda,x[0])).simplify(one);
				v[2]=(v[2]+x[1]).simplify(one);
			}
		}
		auto r=distInit;
		r.copyNonState(this);
		static int unique=0;
		string tmp="`expectation"~lowNum(++unique);
		addTmpVar(tmp);
		foreach(k,v;byFrame){
			auto e=(v[1]/v[2]).simplify(one);
			foreach(x;v[0])
				r.add(dRUpdate(x[0],tmp,e).simplify(one),x[1]);
		}
		this=r;
		return dField(db1,tmp);
	}
	Dist pushFrame(){
		return map(dLambda(dRecord(["`frame":db1])));
	}
	Dist popFrame(string tmpVar){
		addTmpVar(tmpVar);
		return map(dLambda(dRUpdate(dField(db1,"`frame"),tmpVar,dField(db1,"`value"))));
	}
	Dist flatMap(DLambda[] lambdas){
		auto r=distInit;
		r.copyNonState(this);
		foreach(k,v;state){
			foreach(lambda;lambdas){
				auto app=dApply(lambda,k).simplify(one);
				auto val=app[0.dℚ].simplify(one),scale=app[1.dℚ].simplify(one);
				r.add(val,(v*scale).simplify(one));
			}
		}
		return r;
	}
	Dist assertTrue(DLambda lambda){
		if(opt.noCheck) return this;
		auto r=distInit;
		r.copyNonState(this);
		foreach(k,v;state){
			auto cond=dApply(lambda,k).simplify(one);
			if(cond == one || cond == zero){
				if(cond == zero){
					r.error = (r.error + v).simplify(one);
				}else{
					r.add(k,v);
				}
			}else{
				r.error = (r.error + v*dIvr(DIvr.Type.eqZ,cond)).simplify(one);
				r.add(k,(v*cond).simplify(one));
			}
		}
		return r;
	}
	Dist eraseErrors(){
		auto r=dup();
		r.error=zero;
		return r;
	}
	Dist observe(DLambda lambda){
		auto r=distInit;
		r.copyNonState(this);
		foreach(k,v;state){
			auto cond=dApply(lambda,k).simplify(one);
			if(cond == one || cond == zero){
				if(cond == one) r.add(k,v);
			}else{
				r.add(k,(v*cond).simplify(one));
			}
		}
		return r;
	}
	Distribution toDistribution(){
		auto r=new Distribution();
		string name="r";
	Louter:for(;;){ // avoid variable capturing. TODO: make more efficient
			foreach(k,v;state){
				if(k.hasFreeVar(dVar(name))||v.hasFreeVar(dVar(name))){
					name~="'";
					continue Louter;
				}
			}
			break;
		}
		auto var=r.declareVar(name);
		r.distribution=zero;
		foreach(k,v;state) r.distribution=r.distribution+v*dDiscDelta(var,dField(k,"`value"));
		r.error=error;
		r.simplify();
		r.orderFreeVars([var],false);
		return r;
	}
	DExpr flip(DExpr p){
		// TODO: check that p is in [0,1]
		static int unique=0;
		auto tmp="`flip"~lowNum(++unique);
		addTmpVar(tmp);
		this=flatMap(
			[dLambda(dTuple([dRUpdate(db1,tmp,zero),(one-p).simplify(one)])),
			 dLambda(dTuple([dRUpdate(db1,tmp,one),p]))]);
		if(opt.backend==InferenceMethod.simulate) pickOne();
		return dField(db1,tmp);
	}
	DExpr uniformInt(DExpr arg){
		// TODO: check constraints on arguments
		auto r=distInit;
		r.copyNonState(this);
		auto lambda=dLambda(arg);
		static int unique=0;
		auto tmp="`uniformInt"~lowNum(++unique);
		r.addTmpVar(tmp);
		foreach(k,v;state){
			auto ab=dApply(lambda,k).simplify(one);
			auto a=ab[0.dℚ].simplify(one), b=ab[1.dℚ].simplify(one);
			auto az=a.isInteger(), bz=b.isInteger();
			assert(az&&bz,text("TODO: ",a," ",b));
			auto num=dℚ(bz.c.num-az.c.num+1);
			if(num.c>0){
				auto nv=(v/num).simplify(one);
				for(ℤ i=az.c.num;i<=bz.c.num;++i) r.add(dRUpdate(k,tmp,i.dℚ).simplify(one),nv);
			}else r.error = (r.error + v).simplify(one);
		}
		this=r;
		if(opt.backend==InferenceMethod.simulate) pickOne();
		return dField(db1,tmp);
	}
	DExpr categorical(DExpr arg){
		auto r=distInit;
		r.copyNonState(this);
		auto lambda=dLambda(arg);
		static int unique=0;
		auto tmp="`categorical"~lowNum(++unique);
		r.addTmpVar(tmp);
		foreach(k,v;state){
			auto p=dApply(lambda,k).simplify(one);
			auto l=dField(p,"length").simplify(one);
			auto lz=l.isInteger();
			assert(!!lz,"TODO");
			if(lz!=zero){
				// TODO: check other preconditions
				for(ℤ i=0.ℤ;i<lz.c.num;++i)
					r.add(dRUpdate(k,tmp,i.dℚ).simplify(one),(v*p[i.dℚ]).simplify(one));
			}else r.error = (r.error + v).simplify(one);
		}
		this=r;
		if(opt.backend==InferenceMethod.simulate) pickOne();
		return dField(db1,tmp);
	}
	void assignTo(DExpr lhs,DExpr rhs){
		void assignToImpl(DExpr lhs,DExpr rhs){
			if(auto id=cast(DNVar)lhs){
				auto lambda=dLambda(dRUpdate(db1,id.name,rhs));
				this=map(lambda);
			}else if(auto idx=cast(DIndex)lhs){
				assignTo(idx.e,dIUpdate(idx.e,idx.i,rhs));
			}else if(auto fe=cast(DField)lhs){
				if(fe.e == db1){
					assignTo(dVar(fe.f),rhs);
					return;
				}
				assignTo(fe.e,dRUpdate(fe.e,fe.f,rhs));
			}else if(auto tpl=cast(DTuple)lhs){
				foreach(i;0..tpl.values.length)
					assignTo(tpl[i],rhs[i.dℚ].simplify(one));
			}else if(cast(DPlus)lhs||cast(DMult)lhs){
				// TODO: this could be the case (if cond { a } else { b }) = c;
				// (this is also not handled in the symbolic backend at the moment)
			}else{
				assert(0,text("TODO: ",lhs," = ",rhs));
			}
		}
		assignToImpl(lhs,rhs);
	}
	DExpr call(FunctionDef fun,DExpr thisExp,DExpr arg,Scope sc){
		auto ncur=pushFrame();
		if(fun.isConstructor) ncur=ncur.map(dLambda(dRUpdate(db1,fun.thisVar.getName,dRecord())));
		if(thisExp) ncur=ncur.map(dLambda(dRUpdate(db1,fun.contextName,inFrame(thisExp))));
		else if(fun.isNested) ncur=ncur.map(dLambda(dRUpdate(db1,fun.contextName,inFrame(buildContextFor(fun,sc)))));
		if(fun.isNested&&fun.isConstructor) ncur=ncur.map(dLambda(dRUpdate(db1,fun.thisVar.getName,dRecord([fun.contextName:dField(db1,fun.contextName)]))));
		if(fun.isTuple){
			DExpr updates=db1;
			foreach(i,prm;fun.params){
				updates=dRUpdate(updates,prm.getName,inFrame(arg[i.dℚ]));
			}
			if(updates != db1) ncur=ncur.map(dLambda(updates));
		}else{
			assert(fun.params.length==1);
			ncur=ncur.map(dLambda(dRUpdate(db1,fun.params[0].getName,inFrame(arg))));
		}
		auto intp=Interpreter(fun,fun.body_,ncur,true);
		auto nndist = distInit();
		intp.runFun(nndist);
		static uniq=0;
		string tmp="`call"~lowNum(++uniq);
		this=nndist.popFrame(tmp);
		if(thisExp&&!fun.isConstructor){
			assignTo(thisExp,dField(db1,tmp)[1.dℚ]);
			assignTo(dVar(tmp),dField(db1,tmp)[0.dℚ]);
		}
		return dField(db1,tmp);
	}
	private Dist callImpl(DExpr fun,DExpr arg){
		this=pushFrame();
		auto f=dLambda(inFrame(fun)), a=dLambda(inFrame(arg));
		auto r=distInit;
		r.copyNonState(this);
		MapX!(FunctionDef,MapX!(DExpr,DExpr)) byFun;
		foreach(k,v;state){
			auto cf=dApply(f,k).simplify(one);
			auto ca=dApply(a,k).simplify(one);
			FunctionDef fun;
			DExpr ctx;
			if(auto bcf=cast(DDPContextFun)cf){
				fun=bcf.def;
				ctx=bcf.ctx;
			}else if(auto bff=cast(DDPFun)cf) fun=bff.def;
			else assert(0,text(cf," ",typeid(cf)));
			DExpr nk=k;
			if(fun.isTuple){
				foreach(i,prm;fun.params)
					nk=dRUpdate(nk,prm.getName,ca[i.dℚ]).simplify(one);
			}else{
				assert(fun.params.length==1);
				nk=dRUpdate(nk,fun.params[0].getName,ca).simplify(one);
			}
			assert(!!fun.context==!!ctx,text(fun.context," ",ctx," ",cf));
			if(ctx) nk=dRUpdate(nk,fun.contextName,ctx).simplify(one);
			if(fun !in byFun) byFun[fun]=typeof(byFun[fun]).init;
			byFun[fun][nk]=v;
		}
		foreach(fun,kv;byFun){
			auto ncur=distInit;
			ncur.state=kv;
			ncur.copyNonState(this);
			auto intp=Interpreter(fun,fun.body_,ncur,true);
			auto nndist = distInit();
			intp.runFun(nndist);
			r+=nndist;
		}
		return r;
	}
	DExpr call(DExpr fun,DExpr arg){
		auto r=callImpl(fun,arg);
		static uniq=0;
		string tmp="`call'"~lowNum(++uniq);
		this=r.popFrame(tmp);
		return dField(db1,tmp);
	}
	Dist normalize(){
		auto r=distInit();
		r.copyNonState(this);
		DExpr tot=r.error;
		foreach(k,v;state) tot=(tot+v).simplify(one);
		if(!opt.noCheck && tot == zero) r.error=one;
		else if(cast(Dℚ)tot) foreach(k,v;state) r.add(k,(v/tot).simplify(one));
		else{
			if(!opt.noCheck) r.error=(dIvr(DIvr.Type.neqZ,tot)*r.error+dIvr(DIvr.Type.eqZ,tot)).simplify(one);
			foreach(k,v;state) r.add(k,((v/tot)*dIvr(DIvr.Type.neqZ,tot)).simplify(one));
		}
		return r;
	}
	DExpr infer(DExpr fun){
		assert(opt.backend != InferenceMethod.simulate,"TODO: higher-order inference in simulate backend");
		auto r=distInit;
		r.copyNonState(this);
		static uniq=0;
		string tmp="`infer"~lowNum(++uniq);
		addTmpVar(tmp);
		foreach(k,v;state){
			auto cur=distInit;
			cur.add(k,v);
			cur=cur.callImpl(fun,dTuple([])); // TODO: group calls that depend on identical information
			cur=cur.map(dLambda(dRecord(["`value":dField(db1,"`value")])));
			cur.tmpVars.clear();
			cur=cur.normalize();
			r.add(dRUpdate(k,tmp,dDPDist(cur)),v);
		}
		this=r;
		return dField(db1,tmp);
	}
	DExpr distSample(DExpr dist){
		auto r=distInit;
		r.copyNonState(this);
		auto d=dLambda(dist);
		static uniq=0;
		string tmp="`sample"~lowNum(++uniq);
		r.addTmpVar(tmp);
		foreach(k,v;state){
			auto dbf=cast(DDPDist)dApply(d,k).simplify(one);
			assert(!!dbf,text(dbf," ",d));
			foreach(dk,dv;dbf.dist.state) r.add(dRUpdate(k,tmp,dField(dk,"`value")).simplify(one),(v*dv).simplify(one));
			if(!opt.noCheck) r.error=(r.error+v*dbf.dist.error).simplify(one);
		}
		this=r;
		if(opt.backend==InferenceMethod.simulate) pickOne();
		return dField(db1,tmp);
	}
	DExpr distThen(DExpr dist,DExpr arg){
		// TODO.
		assert(0,"TODO");
	}
	DExpr distExpectation(DExpr dist){
		auto r=distInit;
		r.copyNonState(this);
		auto d=dLambda(dist);
		static uniq=0;
		string tmp="`expectation'"~lowNum(++uniq);
		r.addTmpVar(tmp);
		foreach(k,v;state){
			auto dbf=cast(DDPDist)dApply(d,k).simplify(one);
			assert(!!dbf,text(dbf," ",d));
			DExpr val1=zero,val2=zero;
			foreach(dk,dv;dbf.dist.state){
				val1=(val1+dv*dField(dk,"`value")).simplify(one);
				val2=(val2+dv).simplify(one);
			}
			if(!opt.noCheck&&val2==zero) r.error=(r.error+v).simplify(one);
			else if(cast(Dℚ)val2) r.add(dRUpdate(k,tmp,val1/val2).simplify(one),v);
			else{
				if(!opt.noCheck) r.error=(r.error+v*dIvr(DIvr.Type.eqZ,val2)).simplify(one);
				r.add(dRUpdate(k,tmp,val1/val2).simplify(one),(v*dIvr(DIvr.Type.neqZ,val2)).simplify(one));
			}
		}
		this=r;
		return dField(db1,tmp);
	}
	DExpr distError(DExpr dist){
		if(opt.noCheck) return zero;
		auto r=distInit;
		r.copyNonState(this);
		auto d=dLambda(dist);
		static uniq=0;
		string tmp="`error'"~lowNum(++uniq);
		r.addTmpVar(tmp);
		foreach(k,v;state){
			auto dbf=cast(DDPDist)dApply(d,k).simplify(one);
			assert(!!dbf,text(dbf," ",d));
			DExpr error=dbf.dist.error;
			r.add(dRUpdate(k,tmp,error).simplify(one),v);
		}
		this=r;
		return dField(db1,tmp);		
	}
	void copyNonState(ref Dist rhs){
		this.tupleof[1..$]=rhs.tupleof[1..$];
	}
	void pickOne()in{assert(opt.backend==InferenceMethod.simulate);}body{
		real f = uniform(0.0L,1.0L);
		DExpr cur=zero;
		foreach(k,v;state){
			cur=(cur+v).simplify(one);
			auto r=dIvr(DIvr.Type.leZ,dFloat(f)-cur).simplify(one);
			assert(r == zero || r == one);
			if(r == one){
				error = zero;
				state.clear();
				state[k]=one;
				return;
			}
		}
		cur = (cur+error).simplify(one);
		assert(cur == one);
		state.clear();
		error = one;
	}
	Dist simplify(DExpr facts){
		auto r=distInit;
		r.copyNonState(this);
		foreach(k,v;state)
			r.add(k.simplify(facts),v.simplify(facts));
		return r;
	}
	Dist substitute(DVar var,DExpr expr){
		auto r=distInit;
		r.copyNonState(this);
		foreach(k,v;state)
			r.add(k.substitute(var,expr),v.substitute(var,expr));
		return r;
	}
	Dist incDeBruijnVar(int di, int free){
		auto r=distInit;
		r.copyNonState(this);
		foreach(k,v;state)
			r.add(k.incDeBruijnVar(di,free),v.incDeBruijnVar(di,free));
		return r;
	}
	int freeVarsImpl(scope int delegate(DVar) dg,ref DExprSet visited){
		foreach(k,v;state){
			if(auto r=k.freeVarsImpl(dg,visited)) return r;
			if(auto r=v.freeVarsImpl(dg,visited)) return r;
		}
		return 0;
	}
}

DExpr inFrame(DExpr arg){
	return arg.substitute(db1,dField(db1,"`frame"));
}


class DDPFun: DExpr{
	FunctionDef def;
	alias subExprs=Seq!def;
	override string toStringImpl(Format formatting,Precedence prec,int binders){
		return def.name.name;
	}
	mixin Constant;
}
mixin FactoryFunction!DDPFun;
class DDPContextFun: DExpr{
	FunctionDef def;
	DExpr ctx;
	alias subExprs=Seq!(def,ctx);
	override string toStringImpl(Format formatting,Precedence prec,int binders){
		return text(def.name?def.name.name:text("(",def,")"),"@(",ctx.toStringImpl(formatting,Precedence.none,binders),")");
	}
	mixin Visitors;
	override DExpr simplifyImpl(DExpr facts){ return dDPContextFun(def,ctx.simplify(facts)); }

}
mixin FactoryFunction!DDPContextFun;
class DDPDist: DExpr{
	Dist dist;
	alias subExprs=Seq!dist;
	this(Dist dist)in{assert(!dist.tmpVars.length);}body{ this.dist=dist; }
	override string toStringImpl(Format formatting,Precedence prec,int binders){
		auto d=dist.toDistribution();
		d.addArgs([],true,null);
		return dApply(d.toDExpr(),dTuple([])).simplify(one).toStringImpl(formatting,prec,binders);
	}
	override DExpr simplifyImpl(DExpr facts){ return dDPDist(dist.simplify(facts)); }
	mixin Visitors;
}
DDPDist dDPDist(Dist dist)in{assert(!dist.tmpVars.length);}body{
	static MapX!(TupleX!(MapX!(DExpr,DExpr),DExpr),DDPDist) uniq;
	auto t=tuplex(dist.state,dist.error);
	if(t in uniq) return uniq[t];
	auto r=new DDPDist(dist);
	uniq[t]=r;
	return r;
}

import lexer: Tok;
alias ODefExp=BinaryExp!(Tok!":=");
struct Interpreter{
	FunctionDef functionDef;
	CompoundExp statements;
	Dist cur;
	bool hasFrame=false;
	this(FunctionDef functionDef,CompoundExp statements,DExpr init,bool hasFrame){
		auto cur=distInit;
		cur.state[init]=one;
		this(functionDef,statements,cur,hasFrame);
	}
	this(FunctionDef functionDef,CompoundExp statements,Dist cur,bool hasFrame){
		this.functionDef=functionDef;
		this.statements=statements;
		this.cur=cur;
		this.hasFrame=hasFrame;
	}
	DExpr runExp(Expression e){
		if(!cur.state.length) return zero;
		// TODO: get rid of code duplication
		DExpr doIt(Expression e){
			if(auto pl=cast(PlaceholderExp)e) return dVar(pl.ident.name);
			if(auto id=cast(Identifier)e){
				if(!id.meaning&&id.name=="π") return dΠ;
				if(auto r=lookupMeaning(id)) return r;
				assert(0);
			}
			if(auto fe=cast(FieldExp)e){
				if(isBuiltIn(fe)){
					if(auto at=cast(ArrayTy)fe.e.type){
						assert(fe.f.name=="length");
					}else{
						assert(0,"TODO: first-class built-in methdods");
					}
				}
				return dField(doIt(fe.e),fe.f.name);
			}
			if(auto ae=cast(AddExp)e) return doIt(ae.e1)+doIt(ae.e2);
			if(auto me=cast(SubExp)e) return doIt(me.e1)-doIt(me.e2);
			if(auto me=cast(MulExp)e) return doIt(me.e1)*doIt(me.e2);
			if(cast(DivExp)e||cast(IDivExp)e){
				auto de=cast(ABinaryExp)e;
				auto e1=doIt(de.e1);
				auto e2=doIt(de.e2);
				cur=cur.assertTrue(dLambda(dIvr(DIvr.Type.neqZ,e2)));
				return cast(IDivExp)e?dFloor(e1/e2):e1/e2;
			}
			if(auto me=cast(ModExp)e) return doIt(me.e1)%doIt(me.e2);
			if(auto pe=cast(PowExp)e) return doIt(pe.e1)^^doIt(pe.e2);
			if(auto ce=cast(CatExp)e) return doIt(ce.e1)~doIt(ce.e2);
			if(auto ce=cast(BitOrExp)e) return dBitOr(doIt(ce.e1),doIt(ce.e2));
			if(auto ce=cast(BitXorExp)e) return dBitXor(doIt(ce.e1),doIt(ce.e2));
			if(auto ce=cast(BitAndExp)e) return dBitAnd(doIt(ce.e1),doIt(ce.e2));
			if(auto ume=cast(UMinusExp)e) return -doIt(ume.e);
			if(auto ume=cast(UNotExp)e) return dIvr(DIvr.Type.eqZ,doIt(ume.e));
			if(auto ume=cast(UBitNotExp)e) return -doIt(ume.e)-1;
			if(auto le=cast(LambdaExp)e){
				if(le.fd.isNested){
					return dDPContextFun(le.fd,buildContextFor(le.fd,le.fd.scope_));
				}
				return dDPFun(le.fd);
			}
			if(auto ce=cast(CallExp)e){
				auto id=cast(Identifier)ce.e;
				auto fe=cast(FieldExp)ce.e;
				DExpr thisExp=null;
				if(fe){
					id=fe.f;
					thisExp=doIt(fe.e);
				}
				if(id){
					if(auto fun=cast(FunctionDef)id.meaning){
						auto arg=doIt(ce.arg); // TODO: allow temporaries within arguments
						return cur.call(fun,thisExp,arg,id.scope_);
					}
					if(!fe && isBuiltIn(id)){
						switch(id.name){
							case "Marginal":
								assert(0,"TODO");
							case "sampleFrom":
								Expression[] args;
								if(auto tpl=cast(TupleExp)ce.arg) args=tpl.e;
								else args=[ce.arg];
								assert(args.length);
								auto getArg(){
									return args[1..$].length==1?doIt(args[1]):dTuple(args[1..$].map!doIt.array);
								}
								auto literal=cast(LiteralExp)args[0];
								assert(literal&&literal.lit.type==Tok!"``");
								auto str=literal.lit.str;
								import samplefrom;
								final switch(getToken(str)) with(Token){
									case inferPrecondition:
										return one; // TODO
									case infer:
										return cur.infer(getArg());
									case errorPr:
										return cur.distError(getArg());
									case samplePrecondition:
										return one; // TODO
									case sample:
										if(opt.noCheck){
											assert(args[1..$].length==1);
											return cur.distSample(getArg());
										}else{
											assert(args[1..$].length==2);
											return cur.distSample(getArg()[0.dℚ].simplify(one));
										}
									case expectation:
										if(opt.noCheck){
											assert(args[1..$].length==1);
											return cur.distExpectation(getArg());
										}else{
											assert(args[1..$].length==2);
											return cur.distExpectation(getArg()[0.dℚ].simplify(one));
										}
									case uniformIntPrecondition: // (TODO: remove)
										return one; // TODO
									case uniformInt: // uniformInt
										return cur.uniformInt(getArg());
									case categoricalPrecondition:
										return one; // TODO?
									case categorical:
										return cur.categorical(getArg());
									case binomial:
										assert(args[1..$].length==2);
										DExpr arg=getArg();
										auto n_=arg[0.dℚ], p=arg[1.dℚ].incDeBruijnVar(1,0);
										auto n=n_.incDeBruijnVar(1,0);
										return cur.categorical(dArray(n_+1,dLambda(dNChooseK(n,db1)*p^^db1*(1-p)^^(n-db1))).simplify(one));
									case none:
										static DDPDist[const(char)*] dists; // NOTE: it is actually important that identical strings with different addresses get different entries (parameters are substituted)
										if(str.ptr !in dists){
											auto dist=new Distribution();
											auto info=analyzeSampleFrom(ce,new SimpleErrorHandler(),dist);
											if(info.error) assert(0,"TODO");
											auto retVars=info.retVars,paramVars=info.paramVars,newDist=info.newDist;
											foreach(i,pvar;paramVars){
												auto expr=doIt(args[1+i]);
												newDist=newDist.substitute(pvar,expr); // TODO: use substituteAll
											}
											dist.distribute(newDist);
											auto tmp=dist.declareVar("`tmp");
											dist.initialize(tmp,dTuple(cast(DExpr[])retVars.map!(v=>v.tmp).array),contextTy());
											foreach(v;info.retVars) dist.marginalize(v.tmp);
											dist.simplify();
											auto smpl=distInit();
											void gather(DExpr e,DExpr factor){
												assert(!cast(DInt)e,text("TODO: ",ce.e));
												foreach(s;e.summands){
													foreach(f;s.factors){
														if(auto dd=cast(DDiscDelta)f){
															assert(dd.var == tmp);
															smpl.add(dRecord(["`value":retVars.length==1?dd.e[0.dℚ].simplify(one):dd.e]),(factor*s.withoutFactor(f)).substitute(tmp,dd.e).simplify(one));
														}else if(auto sm=cast(DPlus)f){
															gather(sm,factor*s.withoutFactor(f));
														}
													}
												}
											}
											gather(dist.distribution,one);
											dists[str.ptr]=dDPDist(smpl);
										}
										return cur.distSample(dists[str.ptr]);
									}
							case "Expectation":
								auto arg=doIt(ce.arg);
								return cur.expectation(dLambda(arg),hasFrame);
							default:
								assert(0, text("unsupported: ",id.name));
						}
					}
				}
				auto fun=doIt(ce.e), arg=doIt(ce.arg);
				return cur.call(fun,arg);
			}
			if(auto idx=cast(IndexExp)e) return dIndex(doIt(idx.e),doIt(idx.a[0])); // TODO: bounds checking
			if(auto sl=cast(SliceExp)e) return dSlice(doIt(sl.e),doIt(sl.l),doIt(sl.r)); // TODO: bounds checking
			if(auto le=cast(LiteralExp)e){
				if(le.lit.type==Tok!"0"){
					auto n=le.lit.str.split(".");
					if(n.length==1) n~="";
					return (dℚ((n[0]~n[1]).ℤ)/(ℤ(10)^^n[1].length)).simplify(one);
				}
			}
			if(auto cmp=cast(CompoundExp)e){
				if(cmp.s.length==1)
					return doIt(cmp.s[0]);
			}else if(auto ite=cast(IteExp)e){
				auto cond=runExp(ite.cond);
				auto curP=cur.eraseErrors();
				cur=cur.observe(dLambda(dIvr(DIvr.Type.neqZ,cond).simplify(one)));
				curP=curP.observe(dLambda(dIvr(DIvr.Type.eqZ,cond).simplify(one)));
				auto thenIntp=Interpreter(functionDef,ite.then,cur,hasFrame);
				auto r=dIvr(DIvr.Type.neqZ,cond)*thenIntp.runExp(ite.then.s[0]);
				cur=thenIntp.cur;
				assert(!!ite.othw);
				auto othwIntp=Interpreter(functionDef,ite.othw,curP,hasFrame);
				r=r+dIvr(DIvr.Type.eqZ,cond)*othwIntp.runExp(ite.othw);
				curP=othwIntp.cur;
				cur+=curP;
				return r;
			}else if(auto tpl=cast(TupleExp)e){
				auto dexprs=tpl.e.map!doIt.array;
				return dTuple(dexprs);
			}else if(auto arr=cast(ArrayExp)e){
				auto dexprs=arr.e.map!doIt.array;
				return dArray(dexprs);
			}else if(auto ae=cast(AssertExp)e){
				if(auto c=runExp(ae.e)){
					cur=cur.assertTrue(dLambda(dIvr(DIvr.Type.neqZ,c)));
					return dTuple([]);
				}
			}else if(auto tae=cast(TypeAnnotationExp)e){
				return doIt(tae.e);
			}else if(cast(Type)e)
				return dTuple([]); // 'erase' types
			else{
				enum common=q{
					auto e1=doIt(b.e1),e2=doIt(b.e2);
				};
				if(auto b=cast(AndExp)e){
					auto e1=doIt(b.e1), e2=doIt(b.e2);
					return e1*e2;
				}else if(auto b=cast(OrExp)e){
					DExprSet disjuncts;
					void collect(Expression e){
						if(auto or=cast(OrExp)e){
							collect(or.e1);
							collect(or.e2);
						}else disjuncts.insert(doIt(e));
					}
					collect(e);
					return dIvr(DIvr.Type.neqZ,dPlus(disjuncts));
				}else with(DIvr.Type)if(auto b=cast(LtExp)e){
					mixin(common);
					return dIvr(lZ,e1-e2);
				}else if(auto b=cast(LeExp)e){
					mixin(common);
					return dIvr(leZ,e1-e2);
				}else if(auto b=cast(GtExp)e){
					mixin(common);
					return dIvr(lZ,e2-e1);
				}else if(auto b=cast(GeExp)e){
					mixin(common);
					return dIvr(leZ,e2-e1);
				}else if(auto b=cast(EqExp)e){
					mixin(common);
					return dIvr(eqZ,e2-e1);
				}else if(auto b=cast(NeqExp)e){
					mixin(common);
					return dIvr(neqZ,e2-e1);
				}
			}
			assert(0,text("TODO: ",e));
		}
		return doIt(e);
	}
	void runStm(Expression e,ref Dist retDist){
		if(!cur.state.length) return;
		if(opt.trace) writeln("statement: ",e);
		if(auto nde=cast(DefExp)e){
			auto de=cast(ODefExp)nde.initializer;
			assert(!!de);
			auto lhs=runExp(de.e1).simplify(one), rhs=runExp(de.e2).simplify(one);
			cur.assignTo(lhs,rhs);
		}else if(auto ae=cast(AssignExp)e){
			auto lhs=runExp(ae.e1),rhs=runExp(ae.e2);
			cur.assignTo(lhs,rhs);
		}else if(isOpAssignExp(e)){
			DExpr perform(DExpr a,DExpr b){
				if(cast(OrAssignExp)e) return dIvr(DIvr.Type.neqZ,dIvr(DIvr.Type.neqZ,a)+dIvr(DIvr.Type.neqZ,b));
				if(cast(AndAssignExp)e) return dIvr(DIvr.Type.neqZ,a)*dIvr(DIvr.Type.neqZ,b);
				if(cast(AddAssignExp)e) return a+b;
				if(cast(SubAssignExp)e) return a-b;
				if(cast(MulAssignExp)e) return a*b;
				if(cast(DivAssignExp)e||cast(IDivAssignExp)e){
					cur=cur.assertTrue(dLambda(dIvr(DIvr.Type.neqZ,b)));
					return cast(IDivAssignExp)e?dFloor(a/b):a/b;
				}
				if(cast(ModAssignExp)e) return a%b;
				if(cast(PowAssignExp)e){
					// TODO: enforce constraints on domain
					return a^^b;
				}
				if(cast(CatAssignExp)e) return a~b;
				if(cast(BitOrAssignExp)e) return dBitOr(a,b);
				if(cast(BitXorAssignExp)e) return dBitXor(a,b);
				if(cast(BitAndAssignExp)e) return dBitAnd(a,b);
				assert(0);
			}
			auto be=cast(ABinaryExp)e;
			assert(!!be);
			auto lhs=runExp(be.e1); // TODO: keep lhs stable!
			auto rhs=runExp(be.e2);
			cur.assignTo(lhs,perform(lhs,rhs));
		}else if(auto call=cast(CallExp)e){
			runExp(call);
		}else if(auto ite=cast(IteExp)e){
			auto cond=runExp(ite.cond);
			auto curP=cur.eraseErrors();
			cur=cur.observe(dLambda(dIvr(DIvr.Type.neqZ,cond)));
			curP=curP.observe(dLambda(dIvr(DIvr.Type.eqZ,cond).simplify(one)));
			auto thenIntp=Interpreter(functionDef,ite.then,cur,hasFrame);
			thenIntp.run(retDist);
			cur=thenIntp.cur;
			if(ite.othw){
				auto othwIntp=Interpreter(functionDef,ite.othw,curP,hasFrame);
				othwIntp.run(retDist);
				curP=othwIntp.cur;
			}
			cur+=curP;
		}else if(auto re=cast(RepeatExp)e){
			auto rep=runExp(re.num).simplify(one);
			if(auto z=rep.isInteger()){
				auto intp=Interpreter(functionDef,re.bdy,cur,hasFrame);
				foreach(x;0.ℤ..z.c.num){
					if(opt.trace) writeln("repetition: ",x+1);
					intp.run(retDist);
					// TODO: marginalize locals
				}
				cur=intp.cur;
			}else{
				auto bound=dFloor(rep);
				auto intp=Interpreter(functionDef,re.bdy,distInit(),hasFrame);
				intp.cur.state = cur.state;
				cur.state=typeof(cur.state).init;
				for(ℤ x=0;;++x){
					cur += intp.cur.observe(dLambda(dIvr(DIvr.Type.leZ,bound-x)));
					intp.cur = intp.cur.observe(dLambda(dIvr(DIvr.Type.lZ,x-bound)));
					intp.cur.error = zero;
					if(!intp.cur.state.length) break;
					if(opt.trace) writeln("repetition: ",x+1);
					intp.run(retDist);
				}
			}
		}else if(auto fe=cast(ForExp)e){
			auto l=runExp(fe.left).simplify(one), r=runExp(fe.right).simplify(one);
			auto lz=l.isInteger(),rz=r.isInteger();
			if(lz&&rz){
				auto intp=Interpreter(functionDef,fe.bdy,cur,hasFrame);
				for(ℤ j=lz.c.num+cast(int)fe.leftExclusive;j+cast(int)fe.rightExclusive<=rz.c.num;j++){
					if(opt.trace) writeln("loop-index: ",j);
					intp.cur.assignTo(dVar(fe.var.name),dℚ(j));
					intp.run(retDist);
					// TODO: marginalize locals
				}
				cur=intp.cur;
			}else{
				static uniq=0;
				auto tmp="`loopIndex"~lowNum(++uniq);
				cur.assignTo(dVar(tmp),fe.leftExclusive?dFloor(l)+1:dCeil(l));
				auto bound=fe.rightExclusive?dCeil(r)-1:dFloor(r);
				auto intp=Interpreter(functionDef,fe.bdy,distInit(),hasFrame);
				intp.cur.state = cur.state;
				cur.state=typeof(cur.state).init;
				auto cond = dLambda(dIvr(DIvr.Type.leZ,dField(db1,tmp)-bound).simplify(one));
				auto ncond = dLambda(dIvr(DIvr.Type.lZ,bound-dField(db1,tmp)).simplify(one));
				auto upd = (dField(db1,tmp)+1).simplify(one);
				for(int x=0;;++x){
					cur += intp.cur.observe(ncond);
					intp.cur = intp.cur.observe(cond);
					intp.cur.error = zero;
					if(!intp.cur.state.length) break;
					intp.cur.assignTo(dVar(fe.var.name),dField(db1,tmp));
					if(opt.trace) writeln("repetition: ",x+1);
					intp.run(retDist);
					intp.cur.assignTo(dVar(tmp),upd);
					// TODO: marginalize locals
				}
			}
		}else if(auto we=cast(WhileExp)e){
			auto intp=Interpreter(functionDef,we.bdy,distInit(),hasFrame);
			intp.cur.state=cur.state;
			cur.state=typeof(cur.state).init;
			while(intp.cur.state.length){
				auto rcond = intp.runExp(we.cond).simplify(one);
				auto cond = dLambda(dIvr(DIvr.Type.neqZ,rcond).simplify(one));
				auto ncond = dLambda(dIvr(DIvr.Type.eqZ,rcond).simplify(one));
				cur += intp.cur.observe(ncond);
				intp.cur = intp.cur.observe(cond);
				intp.cur.error = zero;
				intp.run(retDist);
				// TODO: marginalize locals
			}
		}else if(auto re=cast(ReturnExp)e){
			auto value = runExp(re.e);
			if(functionDef.context&&functionDef.contextName.startsWith("this"))
				value = dTuple([value,dField(db1,functionDef.contextName)]);
			auto rec=["`value":value];
			if(hasFrame) rec["`frame"]=dField(db1,"`frame");
			retDist += cur.map(dLambda(dRecord(rec)));
			cur=distInit;
		}else if(auto ae=cast(AssertExp)e){
			auto cond=dIvr(DIvr.Type.neqZ,runExp(ae.e));
			cur=cur.assertTrue(dLambda(cond));
		}else if(auto oe=cast(ObserveExp)e){
			assert(opt.backend != InferenceMethod.simulate,"TODO: observe with --simulate");
			auto cond=dIvr(DIvr.Type.neqZ,runExp(oe.e));
			cur=cur.observe(dLambda(cond));
		}else if(auto ce=cast(CommaExp)e){
			runStm(ce.e1,retDist);
			runStm(ce.e2,retDist);
		}else if(cast(Declaration)e){
			// do nothing
		}else{
			assert(0,text("TODO: ",e));
		}
		cur=cur.marginalizeTemporaries();
	}
	void run(ref Dist retDist){
		foreach(s;statements.s){
			runStm(s,retDist);
			// writeln("cur: ",cur);
		}
	}
	void runFun(ref Dist retDist){
		run(retDist);
		retDist+=cur;
		cur=distInit();
	}
}
