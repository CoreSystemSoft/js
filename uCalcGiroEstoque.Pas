unit uCalcGiroEstoque;

interface

uses
  System.SysUtils, System.Generics.Collections, System.Generics.Defaults,
  System.Math, System.DateUtils, FireDAC.Comp.Client;

type
  TAcaoEstoque = (acNormal, acReposicao, acPromocao, acEncalhado);

  TGiroProduto = record
    Produto: Integer;
    Descricao: string;
    Loja: Integer;
    Tamanho: string;
    Cor: string;

    Vendido6M: Double;
    MediaMensal: Double;
    MediaDiaria: Double;

    Estoque: Double;
    Giro: Double;

    Classificacao: string;
    Acao: TAcaoEstoque;

    UltimaVenda: TDateTime;
    DiasSemVenda: Integer;
  end;

  TRemanejamento = record
    Produto: Integer;
    Descricao: string;
    Tamanho: string;
    Cor: string;
    LojaSaida: Integer;
    LojaEntrada: Integer;
    Qtde: Integer;
  end;

  TCalcGiroEstoque = class
  private
    FConn: TFDConnection;
    FLista: TList<TGiroProduto>;
    FRemanejamentos: TList<TRemanejamento>;

    function MediaGeral: Double;
    procedure Classificar;
    procedure DefinirAcoes;
    procedure GerarRemanejamento;

  public
    constructor Create(AConn: TFDConnection);
    destructor Destroy; override;

    procedure Processar;

    property Lista: TList<TGiroProduto> read FLista;
    property Remanejamentos: TList<TRemanejamento> read FRemanejamentos;
  end;

implementation

constructor TCalcGiroEstoque.Create(AConn: TFDConnection);
begin
  FConn := AConn;
  FLista := TList<TGiroProduto>.Create;
  FRemanejamentos := TList<TRemanejamento>.Create;
end;

destructor TCalcGiroEstoque.Destroy;
begin
  FLista.Free;
  FRemanejamentos.Free;
  inherited;
end;

procedure TCalcGiroEstoque.Processar;
var
  Q: TFDQuery;
  R: TGiroProduto;
begin
  FLista.Clear;

  Q := TFDQuery.Create(nil);
  try
    Q.Connection := FConn;

    Q.SQL.Text :=
    'SELECT V.LOJA, V.PRODUTO, V.DESCRICAO, V.TAMANHO, V.COR, V.COR_ID, '+
    'V.VENDIDO_6M, V.ULTIMA_VENDA, '+
    '(V.VENDIDO_6M / 6.0) MEDIA_MENSAL, '+
    '(V.VENDIDO_6M / 180.0) MEDIA_DIARIA, '+
    'COALESCE(E.SALDO,0) SALDO '+
    'FROM ('+
    ' SELECT S.LOJA, SI.PRODUTO, SI.TAMANHO, '+
    ' SI.COR AS COR_ID, CR.DESCRICAO AS COR, EST.DESCRICAO, '+
    ' SUM(SI.QUANTIDADE) VENDIDO_6M, MAX(S.DT_EMISSAO) ULTIMA_VENDA '+
    ' FROM SAIDAITEM SI '+
    ' JOIN SAIDA S ON S.CODIGO = SI.SAIDA '+
    ' JOIN COR CR ON CR.CODIGO = SI.COR '+
    ' JOIN ESTOQUE EST ON EST.CODIGO = SI.PRODUTO '+
    ' WHERE S.DT_EMISSAO >= CURRENT_DATE - 180 '+
    ' GROUP BY S.LOJA, SI.PRODUTO, SI.TAMANHO, SI.COR, CR.DESCRICAO, EST.DESCRICAO '+
    ') V '+
    'LEFT JOIN ('+
    ' SELECT CODIGO PRODUTO, TAMANHO, COR, QTD_1 SALDO, 1 LOJA FROM ESTOQUEITEM '+
    ' UNION ALL SELECT CODIGO, TAMANHO, COR, QTD_2, 2 FROM ESTOQUEITEM '+
    ' UNION ALL SELECT CODIGO, TAMANHO, COR, QTD_3, 3 FROM ESTOQUEITEM '+
    ' UNION ALL SELECT CODIGO, TAMANHO, COR, QTD_4, 4 FROM ESTOQUEITEM '+
    ' UNION ALL SELECT CODIGO, TAMANHO, COR, QTD_5, 5 FROM ESTOQUEITEM '+
    ') E ON E.PRODUTO = V.PRODUTO '+
    'AND E.LOJA = V.LOJA '+
    'AND E.TAMANHO = V.TAMANHO '+
    'AND E.COR = V.COR_ID';

    Q.Open;

    while not Q.Eof do
    begin
      R.Produto := Q.FieldByName('PRODUTO').AsInteger;
      R.Descricao := Q.FieldByName('DESCRICAO').AsString;
      R.Loja := Q.FieldByName('LOJA').AsInteger;
      R.Tamanho := Q.FieldByName('TAMANHO').AsString;
      R.Cor := Q.FieldByName('COR').AsString;

      R.Vendido6M := Q.FieldByName('VENDIDO_6M').AsFloat;
      R.MediaMensal := Q.FieldByName('MEDIA_MENSAL').AsFloat;
      R.MediaDiaria := Q.FieldByName('MEDIA_DIARIA').AsFloat;
      R.Estoque := Q.FieldByName('SALDO').AsFloat;

      if R.Estoque > 0 then
        R.Giro := R.Vendido6M / R.Estoque
      else
        R.Giro := 0;

      R.UltimaVenda := Q.FieldByName('ULTIMA_VENDA').AsDateTime;

      if R.UltimaVenda > 0 then
        R.DiasSemVenda := DaysBetween(Now, R.UltimaVenda)
      else
        R.DiasSemVenda := 999;

      FLista.Add(R);
      Q.Next;
    end;

  finally
    Q.Free;
  end;

  Classificar;
  DefinirAcoes;
  GerarRemanejamento;
end;

function TCalcGiroEstoque.MediaGeral: Double;
var Item: TGiroProduto;
begin
  Result := 0;
  for Item in FLista do
    Result := Result + Item.Giro;

  if FLista.Count > 0 then
    Result := Result / FLista.Count;
end;

procedure TCalcGiroEstoque.Classificar;
var i: Integer; Item: TGiroProduto; Media: Double;
begin
  Media := MediaGeral;

  for i := 0 to FLista.Count - 1 do
  begin
    Item := FLista[i];

    if Item.Giro > Media then
      Item.Classificacao := 'ALTO'
    else if Item.Giro < (Media * 0.5) then
      Item.Classificacao := 'BAIXO'
    else
      Item.Classificacao := 'NORMAL';

    FLista[i] := Item;
  end;
end;

procedure TCalcGiroEstoque.DefinirAcoes;
var i: Integer; Item: TGiroProduto;
begin
  for i := 0 to FLista.Count - 1 do
  begin
    Item := FLista[i];

    if (Item.Estoque > 0) and (Item.DiasSemVenda > 180) then
      Item.Acao := acEncalhado

    else if (Item.Classificacao = 'ALTO') and (Item.Estoque < Item.MediaMensal) then
      Item.Acao := acReposicao

    else if (Item.Classificacao = 'BAIXO') and (Item.Estoque > (Item.MediaMensal * 2)) then
      Item.Acao := acPromocao

    else
      Item.Acao := acNormal;

    FLista[i] := Item;
  end;
end;

procedure TCalcGiroEstoque.GerarRemanejamento;
var
  Destinos, Origens: TList<TGiroProduto>;
  Destino, Origem: TGiroProduto;
  Necessidade, Disponivel, Qt: Double;
  R: TRemanejamento;
  i, j: Integer;
begin
  FRemanejamentos.Clear;

  Destinos := TList<TGiroProduto>.Create;
  Origens  := TList<TGiroProduto>.Create;

  try
    for i := 0 to FLista.Count - 1 do
      if FLista[i].MediaMensal > 0 then
        Destinos.Add(FLista[i]);

    for i := 0 to FLista.Count - 1 do
      if FLista[i].Estoque > (FLista[i].MediaDiaria * 15) then
        Origens.Add(FLista[i]);

    for i := 0 to Destinos.Count - 1 do
    begin
      Destino := Destinos[i];

      Necessidade := (Destino.MediaDiaria * 30) - Destino.Estoque;

      if Necessidade <= 0 then Continue;

      for j := 0 to Origens.Count - 1 do
      begin
        Origem := Origens[j];

        if (Origem.Produto = Destino.Produto) and
           (Origem.Tamanho = Destino.Tamanho) and
           (Origem.Cor = Destino.Cor) and
           (Origem.Loja <> Destino.Loja) then
        begin
          Disponivel := Origem.Estoque - (Origem.MediaDiaria * 15);

          if Disponivel <= 0 then Continue;

          Qt := Min(Necessidade, Disponivel);

          if Qt > 0 then
          begin
            R.Produto := Destino.Produto;
            R.Descricao := Destino.Descricao;
            R.Tamanho := Destino.Tamanho;
            R.Cor := Destino.Cor;
            R.LojaSaida := Origem.Loja;
            R.LojaEntrada := Destino.Loja;
            R.Qtde := Trunc(Qt);

            if R.Qtde <= 0 then Continue;

            FRemanejamentos.Add(R);

            Necessidade := Necessidade - R.Qtde;

            if Necessidade <= 0 then Break;
          end;
        end;
      end;
    end;

  finally
    Destinos.Free;
    Origens.Free;
  end;
end;

end.